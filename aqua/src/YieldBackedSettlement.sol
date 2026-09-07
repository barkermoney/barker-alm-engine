// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-07, ETHOnline 2026. New file; no upstream source altered.
///   Adds an `IMakerHooks` target that settles fills against an ERC-4626 vault: redeem-on-fill on
///   the way out, redeposit-on-receive on the way in, with a configurable liquid buffer between.

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IMakerHooks } from "swap-vm/src/interfaces/IMakerHooks.sol";

/// @title YieldBackedSettlement
/// @notice An `IMakerHooks` target that lets a maker's capital sit in an ERC-4626 vault until the
///   moment a fill actually needs it.
///
/// The companion guard (`YieldBackedSolvencyGuard`) makes the *quote* honest: depth is capped at
/// what the vault can redeem. This contract makes the *fill* work: at settlement time the quoted
/// amount has to exist as loose tokens in the maker's wallet, because SwapVM pays the taker with a
/// plain `transferFrom(maker, taker)`. Two hooks bridge that gap:
///
/// - `preTransferOut` — runs before SwapVM pulls `tokenOut` from the maker. If the wallet holds
///   less than the fill needs, the difference is withdrawn from the vault, plus enough on top to
///   restore the maker's liquid buffer. One redemption serves the fill and the next few fills.
///
/// - `postTransferIn` — runs after the taker's `tokenIn` lands in the maker's wallet. Anything
///   above the buffer target goes straight back into that side's vault, so inbound inventory
///   starts earning in the same transaction that delivered it.
///
/// The buffer is the knob between gas and yield. At 0 every fill touches the vault and every
/// incoming dollar is deposited immediately — maximum yield, one vault round-trip per fill. A
/// wider buffer absorbs small fills entirely, at the cost of keeping that slice of capital idle.
///
/// @dev **Trust model.** This contract holds no funds and has no owner. It acts only on allowances
///   the maker grants it, and every token it moves goes between the maker and a vault position
///   *owned by the maker* — `withdraw(..., receiver: maker, owner: maker)` on the way out,
///   `deposit(..., receiver: maker)` on the way back. Calls are gated to the router because hooks
///   move maker allowances on a schedule the maker priced into the order; an open entry point
///   would let anyone force redemptions and churn the position at the maker's gas... but even
///   then the funds could land nowhere except the maker's own wallet and the maker's own vault.
///
/// @dev **What the maker must approve.**
///   1. `tokenOut → router` — the swap itself (SwapVM pulls the payout).
///   2. vault shares → this contract — so `preTransferOut` can withdraw with `owner = maker`.
///   3. `tokenIn → this contract` — so `postTransferIn` can move inbound tokens into the vault.
///
/// @dev **Hook data layout.** Each enabled hook carries `abi.encode(address vault, uint256
///   bufferBps)` as its maker data, fixed when the order is shipped. The two sides are independent:
///   a USDC/USDT maker can back USDC with steakUSDC and USDT with a different vault, or enable
///   only one side by only setting that side's hook bit.
///
/// Powered by SwapVM — © Degensoft Ltd 2025
contract YieldBackedSettlement is IMakerHooks {
    using SafeERC20 for IERC20;

    /// @notice Hooks may only be invoked by the SwapVM router they were shipped against.
    error NotRouter(address caller);

    /// @notice The configured vault does not hold the token this hook is settling.
    error VaultAssetMismatch(address vault, address token);

    /// @notice Even after redeeming everything the vault allows, the fill cannot be covered.
    /// @dev Reaching this means the strategy quoted beyond its backing — i.e. it shipped without
    ///   the solvency guard, or with reserves the guard was not allowed to see.
    error UnbackedFill(uint256 required, uint256 covered);

    /// @notice Buffer is expressed in basis points of the total position; 10_000 means fully liquid.
    error BufferAboveOne(uint256 bufferBps);

    /// @notice Vault capital was redeemed to cover an outbound transfer.
    /// @param redeemed Assets withdrawn from the vault, fill shortfall plus buffer refill
    event RedeemedForFill(
        address indexed maker, bytes32 indexed orderHash, address indexed token, uint256 redeemed, uint256 fillAmount
    );

    /// @notice Inbound inventory above the buffer target was returned to the vault.
    event RedepositedAfterFill(
        address indexed maker, bytes32 indexed orderHash, address indexed token, uint256 deposited, uint256 buffered
    );

    uint256 private constant _BPS = 10_000;

    /// @notice The only address allowed to drive settlement.
    address public immutable ROUTER;

    constructor(address router) {
        ROUTER = router;
    }

    modifier onlyRouter() {
        if (msg.sender != ROUTER) revert NotRouter(msg.sender);
        _;
    }

    /// @inheritdoc IMakerHooks
    /// @dev Deliberately empty. The inbound side settles *after* the transfer, when the tokens are
    ///   real; there is nothing useful to do before them. Gated all the same so an order that
    ///   enables this bit by mistake stays inert rather than becoming an open callable.
    function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
        view
        onlyRouter
    { }

    /// @inheritdoc IMakerHooks
    /// @notice Redeposit-on-receive: sweep inbound inventory above the buffer back into the vault.
    /// @dev `feeIn` is already gone by the time this runs — the wallet balance reflects it — so the
    ///   sweep works from balances, not from `amountIn`.
    function postTransferIn(
        address maker,
        address,
        address tokenIn,
        address,
        uint256,
        uint256,
        uint256,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata
    ) external onlyRouter {
        (IERC4626 vault, uint256 bufferBps) = _config(makerData, tokenIn);

        uint256 loose = IERC20(tokenIn).balanceOf(maker);
        uint256 target = _bufferTarget(loose + vault.maxWithdraw(maker), bufferBps);
        if (loose <= target) return; // inside the buffer; leave it liquid

        uint256 excess;
        unchecked {
            excess = loose - target;
        }

        IERC20(tokenIn).safeTransferFrom(maker, address(this), excess);
        IERC20(tokenIn).forceApprove(address(vault), excess);
        vault.deposit(excess, maker);

        emit RedepositedAfterFill(maker, orderHash, tokenIn, excess, target);
    }

    /// @inheritdoc IMakerHooks
    /// @notice Redeem-on-fill: make sure the wallet can cover the outbound transfer, topping the
    ///   buffer up in the same redemption.
    function preTransferOut(
        address maker,
        address,
        address,
        address tokenOut,
        uint256,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata
    ) external onlyRouter {
        (IERC4626 vault, uint256 bufferBps) = _config(makerData, tokenOut);

        uint256 loose = IERC20(tokenOut).balanceOf(maker);
        uint256 redeemable = vault.maxWithdraw(maker);

        // The buffer target is sized on the position as it will stand after the fill: what leaves
        // for the taker is not capital anymore, so it should not inflate the buffer kept against
        // future fills.
        uint256 positionAfter = loose + redeemable > amountOut ? loose + redeemable - amountOut : 0;
        uint256 desired = amountOut + _bufferTarget(positionAfter, bufferBps);
        if (loose >= desired) return; // fill and buffer are both already covered

        uint256 shortfall;
        unchecked {
            shortfall = desired - loose;
        }
        // The buffer refill is opportunistic — trimmed to what the vault will give. The fill
        // amount is not: coming up short there means the quote was never backed, and the error
        // should say so instead of letting the transfer fail as a generic allowance revert.
        uint256 withdrawable = shortfall < redeemable ? shortfall : redeemable;
        if (loose + withdrawable < amountOut) revert UnbackedFill(amountOut, loose + withdrawable);

        vault.withdraw(withdrawable, maker, maker);

        emit RedeemedForFill(maker, orderHash, tokenOut, withdrawable, amountOut);
    }

    /// @inheritdoc IMakerHooks
    /// @dev Deliberately empty: by the time this runs the payout has left, and the inbound sweep
    ///   already happened in `postTransferIn`. See `preTransferIn` for why it is gated anyway.
    function postTransferOut(address, address, address, address, uint256, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
        view
        onlyRouter
    { }

    /// @notice How much of `token` the maker would hold loose after settlement at this buffer.
    /// @dev Exposed for dashboards and for makers sizing `bufferBps` before shipping a strategy.
    function _bufferTarget(uint256 position, uint256 bufferBps) private pure returns (uint256) {
        return position * bufferBps / _BPS;
    }

    /// @dev Decode and validate a hook's maker data. A vault backing the wrong asset is a shipped
    ///   misconfiguration; fail it loudly on first touch rather than settling nonsense forever.
    function _config(bytes calldata makerData, address token) private view returns (IERC4626 vault, uint256 bufferBps) {
        address vaultAddress;
        (vaultAddress, bufferBps) = abi.decode(makerData, (address, uint256));
        vault = IERC4626(vaultAddress);
        if (vault.asset() != token) revert VaultAssetMismatch(vaultAddress, token);
        if (bufferBps > _BPS) revert BufferAboveOne(bufferBps);
    }
}
