// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BarkerDynamicFeeHook} from "../src/BarkerDynamicFeeHook.sol";

contract BarkerDynamicFeeHookTest is Base {
    using StateLibrary for IPoolManager;

    BarkerDynamicFeeHook internal hook;
    PoolKey internal key;

    uint24 internal constant BASE_FEE = 3000; // 0.30%
    uint24 internal constant MAX_FEE = 50_000; // 5%
    uint24 internal constant SURGE_PER_TICK = 20;
    uint32 internal constant DECAY_BLOCKS = 100;

    /// @dev Low 14 bits must equal AFTER_INITIALIZE | BEFORE_SWAP = 0x1080. On a real chain this
    ///      comes out of CREATE2 salt mining; in a test we can simply place the code there.
    address internal constant HOOK_ADDR = address(uint160(0xBA4E1080));

    bytes32 internal constant FEE_APPLIED_SIG = keccak256("FeeApplied(bytes32,uint24,uint24,int24)");

    function setUp() public {
        setUpBase();

        deployCodeTo(
            "BarkerDynamicFeeHook.sol:BarkerDynamicFeeHook",
            abi.encode(IPoolManager(address(manager)), governance, BASE_FEE, MAX_FEE, SURGE_PER_TICK, DECAY_BLOCKS),
            HOOK_ADDR
        );
        hook = BarkerDynamicFeeHook(HOOK_ADDR);

        key = _poolKey(IHooks(HOOK_ADDR), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        _initPool(key);

        // Two-sided liquidity spanning spot, so swaps have something to trade against.
        vm.prank(bob);
        swapper.addLiquidity(key, -6000, 6000, 1e20);
    }

    // ------------------------------------------------------------ wiring

    function test_hookAddressCarriesRequiredFlags() public pure {
        uint160 flags = uint160(HOOK_ADDR) & Hooks.ALL_HOOK_MASK;
        assertEq(flags, Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    }

    /// @notice A hook deployed at an address without the right flags must fail at construction.
    /// @dev The PoolManager decides which callbacks to make purely from the hook's address, so a
    ///      mis-mined salt otherwise yields a hook that compiles, deploys, and is silently never
    ///      called — a pool that quietly charges a static fee forever.
    function test_constructorRejectsWrongAddress() public {
        address wrong = address(uint160(0xBA4E0000)); // no flags at all
        vm.expectRevert();
        deployCodeTo(
            "BarkerDynamicFeeHook.sol:BarkerDynamicFeeHook",
            abi.encode(IPoolManager(address(manager)), governance, BASE_FEE, MAX_FEE, SURGE_PER_TICK, DECAY_BLOCKS),
            wrong
        );
    }

    /// @notice `afterInitialize` writes the base fee into the pool.
    function test_afterInitialize_setsBaseFee() public view {
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(lpFee, BASE_FEE, "pool should start at the base fee");
    }

    /// @notice A pool created with a static fee but this hook attached is refused outright, rather
    ///         than silently behaving as a static-fee pool that ignores the hook's schedule.
    function test_initialize_revertsOnStaticFeePool() public {
        PoolKey memory staticKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: STATIC_FEE,
            tickSpacing: TICK_SPACING + 1, // distinct pool id
            hooks: IHooks(HOOK_ADDR)
        });

        vm.expectRevert();
        manager.initialize(staticKey, TickMath.getSqrtPriceAtTick(0));
    }

    // ------------------------------------------------------------ the fee schedule

    /// @notice A quiet pool pays the base fee.
    /// @dev "Quiet" means the tick has not moved, not that no trading happened. The first swap
    ///      after initialize compares against the observation seeded at the initial tick, and a
    ///      swap small enough not to cross a tick boundary leaves nothing to charge for either.
    ///      Any swap large enough to move a tick is, by construction, not quiet — which is the
    ///      point of the hook.
    function test_quietPool_chargesBaseFee() public {
        (uint24 fee, uint24 surge, int24 move) = _swapAndReadFee(false, -1e6, 6000);
        assertEq(move, 0, "nothing has moved since initialize");
        assertEq(surge, 0);
        assertEq(fee, BASE_FEE);

        (uint24 fee2, uint24 surge2, int24 move2) = _swapAndReadFee(false, -1e6, 6000);
        assertEq(move2, 0, "dust trading should not move the tick");
        assertEq(surge2, 0, "and so should not be surcharged");
        assertEq(fee2, BASE_FEE);
    }

    /// @notice The smallest move that does cross a tick is charged, at exactly the configured rate.
    /// @dev Pins the surge formula itself rather than only asserting "went up".
    function test_surgeIsProportionalToTicksMoved() public {
        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));

        (uint24 fee, uint24 surge, int24 move) = _swapAndReadFee(false, -1e6, 6000);
        assertGt(move, 0);
        // safe: asserted positive on the line above
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(surge, uint24(uint24(move)) * SURGE_PER_TICK, "surge = ticksMoved * surgePerTick");
        assertEq(fee, BASE_FEE + surge);
    }

    /// @notice Price movement between swaps raises the fee. This is the whole point of the hook:
    ///         the liquidity is being adversely selected precisely when the price is running, so
    ///         that is when it should be paid more.
    function test_movementBetweenSwaps_raisesFee() public {
        // First swap establishes an observation at the current tick.
        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));

        // A large swap moves the price a long way.
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));

        // The next swap sees that movement and pays for it.
        (uint24 fee, uint24 surge, int24 move) = _swapAndReadFee(false, -1e15, 6000);

        assertGt(move, 0, "price should have moved up");
        assertGt(surge, 0, "surge should be charged for the move");
        assertEq(fee, BASE_FEE + surge);
        assertGt(fee, BASE_FEE);
    }

    /// @notice Surge decays back to the base fee as blocks pass without movement.
    function test_surgeDecaysOverBlocks() public {
        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));

        (, uint24 surgeHot,) = _swapAndReadFee(false, -1e15, 6000);
        assertGt(surgeHot, 0);

        // Halfway through the decay window, with no further movement.
        vm.roll(block.number + DECAY_BLOCKS / 2);
        (, uint24 surgeWarm,) = _swapAndReadFee(false, -1, 6000);
        assertLt(surgeWarm, surgeHot, "surge should have decayed");
        assertGt(surgeWarm, 0, "but not all the way, halfway through the window");

        // Past the full window.
        vm.roll(block.number + DECAY_BLOCKS + 1);
        (uint24 feeCold, uint24 surgeCold,) = _swapAndReadFee(false, -1, 6000);
        assertEq(surgeCold, 0, "surge fully decayed");
        assertEq(feeCold, BASE_FEE);
    }

    /// @notice Regression for the Sep 8 incident, replayed on the parameters deployed to Arc
    ///         testnet: a swap's price impact must not be billed to a trader who arrives long after.
    /// @dev On chain, the Sep 4 lifecycle swap moved the pool 1,080 ticks (−368,460 → −367,380). The
    ///      next swap on that pool came 588,318 blocks later, and the Sep 4 build charged it
    ///      `FeeApplied(fee=24600, surge=21600, tickMove=1080)` — the whole move at full rate, because
    ///      it dated the move to when it was observed rather than when it happened. See
    ///      `DEPLOYMENTS.md` and `FEEDBACK.md` §16.
    function test_moveFromLongAgo_isNotCharged_sep8Replay() public {
        vm.prank(governance);
        hook.setParameters(3000, 50_000, 20, 300); // as read back from the Arc testnet deployment

        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));

        vm.roll(block.number + 588_318);

        assertEq(hook.quoteFee(key), 3000, "quote: nothing recent to charge for");
        (uint24 fee, uint24 surge, int24 move) = _swapAndReadFee(false, -1, 6000);
        assertGt(move, 0, "the move is still reported");
        assertEq(surge, 0, "but it is four days old and has fully decayed");
        assertEq(fee, 3000, "so the trader pays the base fee");
    }

    /// @notice The move decays from the block the previous swap made it, at the same linear rate
    ///         as stored surge — pinned to the exact formula, not merely "went down".
    /// @dev Between two `beforeSwap` calls the tick can only have moved by the one swap in
    ///      between, which ran in `lastBlock`. So after `k` blocks the charge must be
    ///      `min(stored + |move| * surgePerTick, maxFee) * (decayBlocks - k) / decayBlocks`.
    function test_moveDecaysFromTheBlockItHappened() public {
        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));

        // A big move, observed and charged in the block it happened: the full rate.
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));
        uint256 snap = vm.snapshotState();
        (, uint24 surgeNow,) = _swapAndReadFee(false, -1, 6000);
        vm.revertToState(snap);

        // The same state, the same move, a quarter of the window later.
        vm.roll(block.number + DECAY_BLOCKS / 4);
        (, uint24 surgeLater, int24 move) = _swapAndReadFee(false, -1, 6000);

        assertGt(move, 0);
        assertGt(surgeNow, 0);
        assertEq(uint256(surgeLater), (uint256(surgeNow) * (DECAY_BLOCKS - DECAY_BLOCKS / 4)) / DECAY_BLOCKS);
    }

    /// @notice No cliff at the end of the window. The fix first proposed on Sep 8 — re-baseline
    ///         once an observation is older than `decayBlocks` — would have charged a move in full
    ///         one block before the window closed and nothing one block after. Decaying the move
    ///         instead leaves only a sliver in the last block, and nothing after.
    function test_noCliffAtTheEndOfTheWindow() public {
        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));

        uint256 snap = vm.snapshotState();
        vm.roll(block.number + DECAY_BLOCKS - 1);
        (, uint24 surgeLast,) = _swapAndReadFee(false, -1, 6000);
        vm.revertToState(snap);
        vm.roll(block.number + DECAY_BLOCKS);
        (, uint24 surgeGone,) = _swapAndReadFee(false, -1, 6000);

        assertGt(surgeLast, 0, "last block of the window: a sliver remains");
        assertLe(surgeLast, MAX_FEE / DECAY_BLOCKS, "and it is only a sliver: at most 1/decayBlocks of the cap");
        assertEq(surgeGone, 0, "window closed: nothing remains");
    }

    /// @notice `quoteFee` agrees with the charge part-way through a decay, not only in the block
    ///         of the move — the case the Sep 4 build's hand-mirrored quote was never tested on.
    function test_quoteFeeMatchesAppliedFee_midDecay() public {
        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));
        vm.roll(block.number + DECAY_BLOCKS / 3);

        uint24 quoted = hook.quoteFee(key);
        (uint24 applied,,) = _swapAndReadFee(false, -1e15, 6000);
        assertEq(quoted, applied);
    }

    /// @notice A violent move pins the fee at the ceiling rather than overflowing it.
    function test_hugeMove_clampsAtMaxFee() public {
        vm.prank(governance);
        hook.setParameters(BASE_FEE, MAX_FEE, 100_000, DECAY_BLOCKS); // absurd surge per tick

        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));

        (uint24 fee, uint24 surge,) = _swapAndReadFee(false, -1e15, 6000);
        assertEq(surge, MAX_FEE, "surge clamped");
        assertEq(fee, MAX_FEE, "fee clamped, not wrapped");
    }

    /// @notice A downward move is charged the same as an upward one — volatility has no direction.
    function test_downwardMoveAlsoRaisesFee() public {
        vm.prank(alice);
        swapper.swap(key, true, -1e16, TickMath.getSqrtPriceAtTick(-6000));
        vm.prank(bob);
        swapper.swap(key, true, -5e18, TickMath.getSqrtPriceAtTick(-6000));

        (uint24 fee, uint24 surge, int24 move) = _swapAndReadFee(true, -1e15, -6000);
        assertLt(move, 0, "price should have moved down");
        assertGt(surge, 0, "a fall is as volatile as a rise");
        assertEq(fee, BASE_FEE + surge);
    }

    /// @notice `quoteFee` must agree with what `beforeSwap` actually charges, or the dashboard and
    ///         the pool tell users different stories.
    function test_quoteFeeMatchesAppliedFee() public {
        vm.prank(alice);
        swapper.swap(key, false, -1e16, TickMath.getSqrtPriceAtTick(6000));
        vm.prank(bob);
        swapper.swap(key, false, -5e18, TickMath.getSqrtPriceAtTick(6000));

        uint24 quoted = hook.quoteFee(key);
        (uint24 applied,,) = _swapAndReadFee(false, -1e15, 6000);

        assertEq(quoted, applied, "quote and charge must match");
    }

    // ------------------------------------------------------------ access control

    function test_hooksRejectDirectCalls() public {
        vm.expectRevert(BarkerDynamicFeeHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_setParameters_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(BarkerDynamicFeeHook.NotGovernance.selector);
        hook.setParameters(1000, 2000, 1, 10);

        vm.prank(governance);
        hook.setParameters(1000, 2000, 1, 10);
        assertEq(hook.baseFee(), 1000);
        assertEq(hook.maxFee(), 2000);
    }

    function test_setParameters_rejectsBaseAboveMax() public {
        vm.prank(governance);
        vm.expectRevert(BarkerDynamicFeeHook.InvalidParameters.selector);
        hook.setParameters(5000, 1000, 1, 10);
    }

    function test_setParameters_rejectsZeroDecayWindow() public {
        vm.prank(governance);
        vm.expectRevert(BarkerDynamicFeeHook.InvalidParameters.selector);
        hook.setParameters(1000, 2000, 1, 0);
    }

    function test_unusedHooksRevert() public {
        vm.expectRevert(BarkerDynamicFeeHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 0);
    }

    // ------------------------------------------------------------ helpers

    /// @dev Runs a swap and returns the fee the hook applied, read back off its own event.
    ///      The PoolManager's `Swap` event carries the applied fee too (`fee` is the override when
    ///      one is set — FEEDBACK.md §8, corrected Sep 10), but only ours carries the surge and the
    ///      tick move that produced it, which is what these tests assert on.
    function _swapAndReadFee(bool zeroForOne, int256 amount, int24 limitTick)
        internal
        returns (uint24 fee, uint24 surge, int24 move)
    {
        vm.recordLogs();
        vm.prank(alice);
        swapper.swap(key, zeroForOne, amount, TickMath.getSqrtPriceAtTick(limitTick));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == HOOK_ADDR && log.topics[0] == FEE_APPLIED_SIG) {
                return abi.decode(log.data, (uint24, uint24, int24));
            }
        }
        revert("no FeeApplied event emitted");
    }
}
