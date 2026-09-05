// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title BarkerDynamicFeeHook
/// @notice A surge-fee hook: the LP fee rises with realized volatility and decays back to a base
///         rate over time.
///
/// @dev Why this exists. A one-sided concentrated liquidity range is a take-profit ladder that
///      earns fees while it waits. A *static* fee rate prices that liquidity identically during a
///      quiet hour and during a violent repricing — which is exactly backwards, because the violent
///      repricing is when the liquidity provider is being adversely selected and needs to be paid
///      more. Meteora's DLMM demonstrated the fix on Solana; v4 hooks are the first time it is
///      expressible on a Uniswap pool without forking anything.
///
///      The measurement is deliberately cheap: we sample the pool tick in `beforeSwap` and compare
///      it to the tick we saw at the previous swap. The difference is the price movement caused by
///      everything that happened in between, which is the realized volatility we want to charge
///      for. No oracle, no external call, two storage slots per pool.
///
/// Permissions: AFTER_INITIALIZE | BEFORE_SWAP  =>  address must end in flags 0x1080.
contract BarkerDynamicFeeHook is IHooks {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /// @dev Flags this hook's address must carry. See `Hooks.sol`.
    uint160 internal constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;

    IPoolManager public immutable poolManager;
    address public immutable governance;

    /// @notice Fee charged when the pool is quiet, in hundredths of a bip (3000 = 0.30%).
    uint24 public baseFee;
    /// @notice Ceiling on base + surge. Never exceeds `LPFeeLibrary.MAX_LP_FEE`.
    uint24 public maxFee;
    /// @notice Surge added per tick of movement observed between swaps.
    uint24 public surgePerTick;
    /// @notice Blocks over which an accumulated surge decays linearly back to zero.
    uint32 public decayBlocks;

    struct Observation {
        int24 lastTick;
        uint32 lastBlock;
        uint24 surge; // surge in effect as of lastBlock, before decay
        bool initialized;
    }

    mapping(PoolId => Observation) public observations;

    event ParametersUpdated(uint24 baseFee, uint24 maxFee, uint24 surgePerTick, uint32 decayBlocks);
    event FeeApplied(PoolId indexed poolId, uint24 fee, uint24 surge, int24 tickMove);

    error NotPoolManager();
    error NotGovernance();
    error HookNotImplemented();
    error InvalidHookAddress();
    error PoolMustUseDynamicFee();
    error InvalidParameters();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _governance,
        uint24 _baseFee,
        uint24 _maxFee,
        uint24 _surgePerTick,
        uint32 _decayBlocks
    ) {
        // The permission bits live in the low bits of this contract's own address, so a
        // mis-mined salt has to fail loudly at construction rather than produce a hook the
        // PoolManager will silently never call.
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != REQUIRED_FLAGS) revert InvalidHookAddress();

        poolManager = _poolManager;
        governance = _governance;
        _setParameters(_baseFee, _maxFee, _surgePerTick, _decayBlocks);
    }

    // ---------------------------------------------------------------- governance

    function setParameters(uint24 _baseFee, uint24 _maxFee, uint24 _surgePerTick, uint32 _decayBlocks)
        external
        onlyGovernance
    {
        _setParameters(_baseFee, _maxFee, _surgePerTick, _decayBlocks);
    }

    function _setParameters(uint24 _baseFee, uint24 _maxFee, uint24 _surgePerTick, uint32 _decayBlocks) internal {
        if (_baseFee > _maxFee || !_maxFee.isValid() || _decayBlocks == 0) revert InvalidParameters();
        baseFee = _baseFee;
        maxFee = _maxFee;
        surgePerTick = _surgePerTick;
        decayBlocks = _decayBlocks;
        emit ParametersUpdated(_baseFee, _maxFee, _surgePerTick, _decayBlocks);
    }

    // ---------------------------------------------------------------- hooks

    /// @dev Sets the pool's starting LP fee. The pool must have been created with the dynamic-fee
    ///      sentinel; otherwise `updateDynamicLPFee` reverts and the pool would have quietly behaved
    ///      as a static-fee pool forever.
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert PoolMustUseDynamicFee();

        poolManager.updateDynamicLPFee(key, baseFee);

        observations[key.toId()] =
            Observation({lastTick: tick, lastBlock: uint32(block.number), surge: 0, initialized: true});

        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Observation memory obs = observations[id];

        (, int24 currentTick,,) = poolManager.getSlot0(id);

        // A pool initialized before this hook was attached has no observation to compare against.
        // Start one and charge the base fee rather than inventing a movement out of tick zero.
        if (!obs.initialized) {
            observations[id] =
                Observation({lastTick: currentTick, lastBlock: uint32(block.number), surge: 0, initialized: true});
            return
                (
                    IHooks.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
                );
        }

        uint24 surge = _decayed(obs.surge, uint32(block.number) - obs.lastBlock);

        int24 move = currentTick - obs.lastTick;
        uint256 absMove = uint256(int256(move < 0 ? -move : move));

        // Saturating: a large move should pin the fee at maxFee, never wrap around.
        uint256 added = absMove * surgePerTick;
        uint256 total = uint256(surge) + added;
        if (total > maxFee) total = maxFee;
        // safe: clamped to maxFee, which is itself a uint24
        // forge-lint: disable-next-line(unsafe-typecast)
        surge = uint24(total);

        observations[id] =
            Observation({lastTick: currentTick, lastBlock: uint32(block.number), surge: surge, initialized: true});

        uint24 fee = baseFee + surge;
        if (fee > maxFee) fee = maxFee;

        emit FeeApplied(id, fee, surge, move);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Surge remaining after linear decay over `decayBlocks`.
    function _decayed(uint24 surge, uint32 elapsed) internal view returns (uint24) {
        if (surge == 0) return 0;
        uint32 d = decayBlocks;
        if (elapsed >= d) return 0;
        // safe: the result is a fraction of `surge`, which is a uint24
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24((uint256(surge) * (d - elapsed)) / d);
    }

    /// @notice The fee a swap would pay right now, without changing state.
    /// @dev For quoting and for the dashboard. Mirrors `beforeSwap` exactly; if you change one,
    ///      change the other.
    function quoteFee(PoolKey calldata key) external view returns (uint24) {
        PoolId id = key.toId();
        Observation memory obs = observations[id];
        if (!obs.initialized) return baseFee;

        (, int24 currentTick,,) = poolManager.getSlot0(id);
        uint24 surge = _decayed(obs.surge, uint32(block.number) - obs.lastBlock);

        int24 move = currentTick - obs.lastTick;
        uint256 absMove = uint256(int256(move < 0 ? -move : move));
        uint256 total = uint256(surge) + absMove * surgePerTick;
        if (total > maxFee) total = maxFee;

        // safe: clamped to maxFee, which is itself a uint24
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 fee = baseFee + uint24(total);
        return fee > maxFee ? maxFee : fee;
    }

    // ---------------------------------------------------------------- unused hooks
    // Not permitted by this hook's address, so the PoolManager never calls them. They revert
    // rather than return a selector so that a mis-mined address surfaces as a failure.

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
