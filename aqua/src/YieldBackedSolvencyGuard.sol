// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-05, ETHOnline 2026. New file; no upstream source altered.
///   Adds an `Extruction` target that caps a maker's quotable depth at what the maker can
///   actually deliver when the backing capital is sitting in an ERC-4626 vault earning yield.

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IStaticExtruction } from "swap-vm/src/instructions/Extruction.sol";
import { SwapQuery, SwapRegisters } from "swap-vm/src/libs/VM.sol";

/// @title YieldBackedSolvencyGuard
/// @notice An `Extruction` target that caps quoted depth at what the maker can actually pay out.
///
/// A yield-backed maker holds almost no loose inventory: the capital lives in an ERC-4626 vault
/// and is redeemed only when a fill demands it. The virtual reserves a strategy quotes against
/// therefore say nothing about solvency, and a strategy shipped with reserves larger than the
/// vault position will quote fills it cannot settle. The taker pays gas to discover this at
/// transfer time, and the maker looks like it is quoting in bad faith.
///
/// This guard closes that gap by rewriting `balanceOut` — the reserve the pricing curve runs on —
/// down to `min(virtual reserve, liquid + redeemable, allowance)` before the curve is evaluated.
/// Because the cap lands on the reserve rather than on the resulting amount, the quote stays *on*
/// the curve: depth shrinks, price walks up the same shape, and every quote the strategy can emit
/// is one the maker can settle.
///
/// @dev Placement matters. This must run **after** the reserves are set (`AQUA`, `StaticBalances`
///   or `DynamicBalances`) and **before** the swap math (`XYCSwap`, `XYCConcentrateSwap`,
///   `PeggedSwap`). Placed after the math it would cap a number nobody reads again.
///
/// @dev Quote/swap consistency is structural here, not a convention. `IExtruction.extruction` and
///   `IStaticExtruction.extruction` share one selector — mutability is not part of a function's
///   identity — so implementing only the `view` form means the quote path (`STATICCALL`) and the
///   swap path (`CALL`) land on the same bytecode. There is no second code path to drift.
///
/// Powered by SwapVM — © Degensoft Ltd 2025
contract YieldBackedSolvencyGuard is IStaticExtruction {
    /// @notice An exact-output request asks for more than the maker can deliver.
    /// @param requested The taker's requested `amountOut`
    /// @param deliverable Liquid balance plus redeemable vault assets, capped by allowance
    error QuoteExceedsSolvency(uint256 requested, uint256 deliverable);

    /// @notice Guard args must be either empty (no vault) or exactly one address.
    error MalformedGuardArgs(uint256 length);

    /// @dev Encoding of `extructionArgs`: an optional 20-byte vault address, nothing else.
    uint256 private constant _VAULT_ARGS_LENGTH = 20;

    /// @notice Cap the outbound reserve at what the maker can actually settle.
    /// @dev Signature is fixed by `IExtruction` / `IStaticExtruction`; unused parameters are the
    ///   static-context flag (both paths behave identically, so it is ignored by construction) and
    ///   `takerData`. Taker data is deliberately not read: solvency is a property of the maker, and
    ///   letting the taker feed this calculation would hand them a lever on their own fill limit.
    /// @param nextPC Program counter, returned unchanged — the guard never branches
    /// @param query Read-only swap information; `maker` and `tokenOut` are read directly
    /// @param swap Incoming registers
    /// @param args `[address vault]`, or empty for a maker holding only loose inventory
    /// @return updatedNextPC `nextPC`, unchanged
    /// @return choppedLength Always 0 — no taker arguments are consumed
    /// @return updatedSwap Registers with `balanceOut` capped
    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    ) external view returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap) {
        uint256 deliverable = deliverableAmount(query.maker, query.tokenOut, _parseVault(args), msg.sender);

        // Exact-output asks for a fixed `amountOut`, which SwapVM guarantees the strategy cannot
        // rewrite. Capping the reserve underneath it would leave the curve to fail as an arithmetic
        // error somewhere downstream; failing here names the actual reason.
        if (!query.isExactIn && swap.amountOut > deliverable) {
            revert QuoteExceedsSolvency(swap.amountOut, deliverable);
        }

        updatedSwap = swap;

        // Only ever downward. A guard that could raise the reserve would be a way to quote depth
        // the strategy never authorised.
        if (updatedSwap.balanceOut > deliverable) {
            updatedSwap.balanceOut = deliverable;
        }

        return (nextPC, 0, updatedSwap);
    }

    /// @notice What the maker could pay out in `token` right now.
    /// @dev Exposed for makers and dashboards sizing a strategy before shipping it: quoting more
    ///   reserve than this is quoting depth the guard will silently trim away.
    /// @param maker The liquidity provider
    /// @param token The token being paid out
    /// @param vault An ERC-4626 vault backing `token`, or the zero address
    /// @param spender The address that will move the tokens — SwapVM's router
    function deliverableAmount(
        address maker,
        address token,
        address vault,
        address spender
    ) public view returns (uint256) {
        uint256 amount = IERC20(token).balanceOf(maker);

        // `maxWithdraw` rather than `convertToAssets(balanceOf)`: the former accounts for the
        // vault's own liquidity and withdrawal limits, and a vault that cannot currently service a
        // redemption is not backing anything, whatever the share price says.
        //
        // A misconfigured vault reverts here rather than degrading to zero. Silent degradation
        // would surface as a maker whose depth mysteriously collapsed; Extruction's own guidance
        // asks for transparent revert conditions.
        if (vault != address(0) && IERC4626(vault).asset() == token) {
            amount += IERC4626(vault).maxWithdraw(maker);
        }

        uint256 allowed = IERC20(token).allowance(maker, spender);
        return amount < allowed ? amount : allowed;
    }

    /// @dev Empty args mean "no vault"; anything other than empty or exactly one address is a
    ///   malformed strategy, and a strategy is immutable once shipped — better to reject it than
    ///   to guess at the maker's intent for the life of the position.
    function _parseVault(bytes calldata args) private pure returns (address vault) {
        if (args.length == 0) return address(0);
        if (args.length != _VAULT_ARGS_LENGTH) revert MalformedGuardArgs(args.length);
        return address(bytes20(args[0:_VAULT_ARGS_LENGTH]));
    }
}
