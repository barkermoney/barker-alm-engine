// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title BarkerV4Positions
/// @notice Opens, holds and closes **one-sided** concentrated liquidity positions on Uniswap v4.
///
/// @dev The product claim in one sentence: a range placed entirely on one side of spot is a
///      systematic execution primitive, not a yield position. Above spot and funded only in the
///      base asset, it is a take-profit ladder that converts to the quote asset as price rises
///      through it — and collects fees the whole way, which is what makes it beat a resting limit
///      order. Below spot and funded only in the quote asset, it is the mirror image: a bid ladder.
///
///      This contract's job is to make that primitive safe to automate. The two things it adds over
///      a bare PoolManager helper are:
///
///      1. **One-sidedness is enforced, not assumed.** A range that straddles spot silently becomes
///         a two-sided market making position that takes impermanent loss from the first block. The
///         difference is one tick of user error. `open` rejects it up front by comparing against the
///         live tick, and then asserts after the fact that the pool actually debited only one asset.
///         The second check is the one that matters: it is the pool's own accounting, not ours.
///
///      2. **Custody stays with the position owner.** Funds are pulled from the owner at open and
///         paid back to the owner at close. A keeper may close and collect — that is the automation —
///         but it can never name a different recipient. The worst a compromised keeper can do is
///         close a position early, into the owner's own wallet.
///
///      Positions are recorded in a registry keyed by an incrementing id, with the position `salt`
///      derived from that id so that two positions on the same range never collide in the
///      PoolManager's accounting.
contract BarkerV4Positions is IUnlockCallback {
    using StateLibrary for IPoolManager;

    enum Side {
        /// Range strictly above spot, funded in currency0. Take-profit ladder.
        Upper,
        /// Range at or below spot, funded in currency1. Bid ladder.
        Lower
    }

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address owner;
        Side side;
        bool closed;
    }

    uint8 private constant ACTION_OPEN = 0;
    uint8 private constant ACTION_CLOSE = 1;
    uint8 private constant ACTION_COLLECT = 2;

    IPoolManager public immutable poolManager;

    address public governance;
    mapping(address => bool) public isKeeper;
    bool public paused;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) internal _positions;

    event GovernanceTransferred(address indexed from, address indexed to);
    event KeeperSet(address indexed keeper, bool allowed);
    event PausedSet(bool paused);
    event PositionOpened(
        uint256 indexed positionId,
        PoolId indexed poolId,
        address indexed owner,
        Side side,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amountFunded
    );
    event PositionClosed(uint256 indexed positionId, PoolId indexed poolId, uint256 amount0Out, uint256 amount1Out);
    event FeesCollected(uint256 indexed positionId, PoolId indexed poolId, uint256 amount0, uint256 amount1);

    error NotGovernance();
    error NotAuthorized();
    error NotPoolManager();
    error Paused();
    error UnknownPosition();
    error PositionAlreadyClosed();
    error ZeroLiquidity();
    error TicksOutOfOrder();
    error TicksNotAligned();
    /// @dev The requested range is not entirely on the requested side of the current price.
    error RangeStraddlesSpot();
    /// @dev The pool debited the asset this side is not supposed to fund. Should be unreachable
    ///      given the pre-check; kept because it is the pool's accounting rather than our arithmetic.
    error NotOneSided();
    error ZeroAddress();
    error TransferFailed(address token);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(IPoolManager _poolManager, address _governance) {
        if (_governance == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        governance = _governance;
        emit GovernanceTransferred(address(0), _governance);
    }

    // ---------------------------------------------------------------- admin

    function transferGovernance(address to) external onlyGovernance {
        if (to == address(0)) revert ZeroAddress();
        emit GovernanceTransferred(governance, to);
        governance = to;
    }

    function setKeeper(address keeper, bool allowed) external onlyGovernance {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Blocks opening new positions. Closing and collecting stay available on purpose —
    ///         pausing must never trap a user's capital in a range.
    function setPaused(bool p) external onlyGovernance {
        paused = p;
        emit PausedSet(p);
    }

    // ---------------------------------------------------------------- views

    function getPosition(uint256 positionId) external view returns (Position memory) {
        Position memory p = _positions[positionId];
        if (p.owner == address(0)) revert UnknownPosition();
        return p;
    }

    /// @notice Uncollected fees owed to a position, as of now.
    function feesOwed(uint256 positionId) external view returns (uint256 fee0, uint256 fee1) {
        Position memory p = _positions[positionId];
        if (p.owner == address(0)) revert UnknownPosition();
        if (p.closed) return (0, 0);
        (fee0, fee1) = poolManager.getFeeGrowthInside(p.key.toId(), p.tickLower, p.tickUpper);
    }

    /// @dev Salt is derived from the position id so two positions sharing a range stay distinct
    ///      in the PoolManager's own accounting.
    function saltFor(uint256 positionId) public pure returns (bytes32) {
        return bytes32(positionId);
    }

    // ---------------------------------------------------------------- lifecycle

    /// @notice Open a one-sided position. Caller funds it and owns it.
    /// @dev The caller must have approved this contract on the funding currency: currency0 for
    ///      `Side.Upper`, currency1 for `Side.Lower`.
    function open(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity, Side side)
        external
        whenNotPaused
        returns (uint256 positionId)
    {
        if (liquidity == 0) revert ZeroLiquidity();
        if (tickLower >= tickUpper) revert TicksOutOfOrder();
        int24 spacing = key.tickSpacing;
        if (tickLower % spacing != 0 || tickUpper % spacing != 0) revert TicksNotAligned();

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // v4 pays out a position entirely in currency0 when the price sits below the range, and
        // entirely in currency1 when it sits at or above. Anything else straddles.
        if (side == Side.Upper) {
            if (currentTick >= tickLower) revert RangeStraddlesSpot();
        } else {
            if (currentTick < tickUpper) revert RangeStraddlesSpot();
        }

        positionId = nextPositionId++;
        _positions[positionId] = Position({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            owner: msg.sender,
            side: side,
            closed: false
        });

        bytes memory result = poolManager.unlock(abi.encode(ACTION_OPEN, abi.encode(positionId, msg.sender)));
        (uint256 amount0, uint256 amount1) = abi.decode(result, (uint256, uint256));

        // The pool's own accounting, not ours. If it debited the wrong side, the range was not
        // where we thought it was.
        if (side == Side.Upper) {
            if (amount1 != 0) revert NotOneSided();
        } else {
            if (amount0 != 0) revert NotOneSided();
        }

        emit PositionOpened(
            positionId,
            key.toId(),
            msg.sender,
            side,
            tickLower,
            tickUpper,
            liquidity,
            side == Side.Upper ? amount0 : amount1
        );
    }

    /// @notice Burn the whole position and send principal plus accrued fees to its owner.
    /// @dev Callable by the owner or by a keeper. Neither can redirect the proceeds.
    function close(uint256 positionId) external returns (uint256 amount0Out, uint256 amount1Out) {
        Position storage p = _positions[positionId];
        if (p.owner == address(0)) revert UnknownPosition();
        if (p.closed) revert PositionAlreadyClosed();
        if (msg.sender != p.owner && !isKeeper[msg.sender]) revert NotAuthorized();

        p.closed = true;

        bytes memory result = poolManager.unlock(abi.encode(ACTION_CLOSE, abi.encode(positionId, p.owner)));
        (amount0Out, amount1Out) = abi.decode(result, (uint256, uint256));

        emit PositionClosed(positionId, p.key.toId(), amount0Out, amount1Out);
    }

    /// @notice Sweep accrued fees to the position owner without touching the principal.
    /// @dev A zero liquidity delta is v4's idiom for "settle my fees and leave the range alone".
    function collect(uint256 positionId) external returns (uint256 amount0, uint256 amount1) {
        Position storage p = _positions[positionId];
        if (p.owner == address(0)) revert UnknownPosition();
        if (p.closed) revert PositionAlreadyClosed();
        if (msg.sender != p.owner && !isKeeper[msg.sender]) revert NotAuthorized();

        bytes memory result = poolManager.unlock(abi.encode(ACTION_COLLECT, abi.encode(positionId, p.owner)));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        emit FeesCollected(positionId, p.key.toId(), amount0, amount1);
    }

    // ---------------------------------------------------------------- unlock callback

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (uint8 action, bytes memory payload) = abi.decode(raw, (uint8, bytes));
        (uint256 positionId, address counterparty) = abi.decode(payload, (uint256, address));

        Position memory p = _positions[positionId];

        int256 liquidityDelta;
        if (action == ACTION_OPEN) {
            liquidityDelta = int256(uint256(p.liquidity));
        } else if (action == ACTION_CLOSE) {
            liquidityDelta = -int256(uint256(p.liquidity));
        } else {
            liquidityDelta = 0; // collect
        }

        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: liquidityDelta,
                salt: saltFor(positionId)
            }),
            ""
        );

        // `delta` already folds in `feesAccrued`; it is decoded only so the caller-facing return
        // value of `collect` is unambiguous about what was fees versus principal.
        feesAccrued;

        uint256 amount0 = _settle(p.key.currency0, delta.amount0(), counterparty);
        uint256 amount1 = _settle(p.key.currency1, delta.amount1(), counterparty);

        return abi.encode(amount0, amount1);
    }

    /// @dev Negative delta means we owe the pool: pull from the position owner. Positive means the
    ///      pool owes us: take straight to the position owner, so funds never rest in this contract.
    /// @return magnitude The absolute amount moved, for the caller's accounting.
    function _settle(Currency currency, int128 amount, address counterparty) internal returns (uint256 magnitude) {
        if (amount < 0) {
            // safe: `amount` is int128 and negative, so its negation fits in uint128
            // forge-lint: disable-next-line(unsafe-typecast)
            magnitude = uint256(uint128(-amount));
            poolManager.sync(currency);
            _safeTransferFrom(Currency.unwrap(currency), counterparty, address(poolManager), magnitude);
            poolManager.settle();
        } else if (amount > 0) {
            // safe: `amount` is int128 and positive
            // forge-lint: disable-next-line(unsafe-typecast)
            magnitude = uint256(uint128(amount));
            poolManager.take(currency, counterparty, magnitude);
        }
    }

    /// @dev Treats a reverting call, an explicit `false`, or a short non-empty return as failure,
    ///      and an empty return as success. Arc's USDC is a shell that delegatecalls into a native
    ///      precompile rather than a plain Solidity ERC-20, so assuming it returns a clean ABI-encoded
    ///      bool is exactly the kind of thing that works on a testnet and surprises you later.
    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, value));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed(token);
    }
}
