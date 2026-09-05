// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BarkerV4Positions} from "../src/BarkerV4Positions.sol";

contract BarkerV4PositionsTest is Base {
    PoolKey internal key;

    function setUp() public {
        setUpBase();
        key = _poolKey(IHooks(address(0)), STATIC_FEE);
        _initPool(key);
    }

    // ------------------------------------------------------------ one-sidedness

    /// @notice A range entirely above spot must consume only currency0 and no currency1.
    /// @dev This is the whole product claim reduced to one assertion. If `spent1` is ever nonzero,
    ///      the "take-profit ladder" is quietly a two-sided market making position taking IL.
    function test_open_upper_consumesOnlyCurrency0() public {
        (uint256 before0, uint256 before1) = _balances(alice);

        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);

        (uint256 after0, uint256 after1) = _balances(alice);
        uint256 spent0 = before0 - after0;
        uint256 spent1 = before1 - after1;

        assertGt(spent0, 0, "should have funded currency0");
        assertEq(spent1, 0, "an upper range must not touch currency1");
        assertEq(positions.getPosition(id).owner, alice);
    }

    /// @notice And the mirror image: a range entirely below spot consumes only currency1.
    function test_open_lower_consumesOnlyCurrency1() public {
        (uint256 before0, uint256 before1) = _balances(alice);

        vm.prank(alice);
        positions.open(key, -1200, -600, 1e18, BarkerV4Positions.Side.Lower);

        (uint256 after0, uint256 after1) = _balances(alice);

        assertEq(before0 - after0, 0, "a lower range must not touch currency0");
        assertGt(before1 - after1, 0, "should have funded currency1");
    }

    /// @notice A range that contains spot is rejected rather than silently opened two-sided.
    function test_open_revertsWhenRangeStraddlesSpot() public {
        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.RangeStraddlesSpot.selector);
        positions.open(key, -600, 600, 1e18, BarkerV4Positions.Side.Upper);
    }

    /// @notice Boundary: `tickLower == currentTick` still straddles, because v4 pays a position in
    ///         currency1 once the price reaches the lower bound. Off-by-one here is a real IL bug.
    function test_open_revertsAtExactSpotBoundary() public {
        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.RangeStraddlesSpot.selector);
        positions.open(key, 0, 600, 1e18, BarkerV4Positions.Side.Upper);
    }

    /// @notice The converse boundary: a lower range ending exactly at spot IS one-sided, because v4
    ///         pays entirely in currency1 when `tick >= tickUpper`.
    function test_open_lowerEndingAtSpotIsAccepted() public {
        (uint256 before0,) = _balances(alice);

        vm.prank(alice);
        positions.open(key, -600, 0, 1e18, BarkerV4Positions.Side.Lower);

        (uint256 after0,) = _balances(alice);
        assertEq(before0 - after0, 0, "should still be one-sided in currency1");
    }

    function test_open_revertsOnUnalignedTicks() public {
        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.TicksNotAligned.selector);
        positions.open(key, 601, 1200, 1e18, BarkerV4Positions.Side.Upper);
    }

    function test_open_revertsOnInvertedTicks() public {
        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.TicksOutOfOrder.selector);
        positions.open(key, 1200, 600, 1e18, BarkerV4Positions.Side.Upper);
    }

    function test_open_revertsOnZeroLiquidity() public {
        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.ZeroLiquidity.selector);
        positions.open(key, 600, 1200, 0, BarkerV4Positions.Side.Upper);
    }

    // ------------------------------------------------------------ the take-profit claim

    /// @notice Open a range above spot, let price run through it, close. The realised sale price
    ///         should be the range's geometric mean **plus exactly the fee premium**.
    ///
    /// @dev This is the whole thesis as an assertion, and the two halves say different things.
    ///
    ///      The geometric mean is the honest cost of laddering: selling across [+6%, +12%] averages
    ///      ~+9%, which is *worse* than a limit order resting at +12%. A ladder that only had that
    ///      going for it would be a worse execution primitive, not a better one.
    ///
    ///      What pays for the difference is the fee. For an exact-input swap the fee is taken off
    ///      the input while the whole input still accrues to the liquidity, so a fully crossed range
    ///      realises `geometricMean / (1 - fee)` — a premium of `fee / (1 - fee)`, which at a 0.30%
    ///      pool is 0.3009%. That premium is the entire economic case for using a range instead of
    ///      a limit order, so it is asserted to four decimal places rather than waved at.
    ///
    ///      This is also why the strategy's pool selection is about fee flow: below roughly 1.5% of
    ///      fees per week, the premium stops covering the averaging-down and a limit order wins.
    ///      The probe measured the geometric-mean half of this on Arc testnet (+8.46% realised on a
    ///      +5.25%..+11.76% range).
    function test_crossedUpperRange_realisesGeometricMeanPlusFee() public {
        int24 tickLower = 600;
        int24 tickUpper = 1200;

        (uint256 before0,) = _balances(alice);
        vm.prank(alice);
        uint256 id = positions.open(key, tickLower, tickUpper, 1e18, BarkerV4Positions.Side.Upper);
        (uint256 mid0,) = _balances(alice);
        uint256 principal0 = before0 - mid0;

        // Push the price above the range: buy currency0 with currency1.
        vm.prank(bob);
        swapper.swap(key, false, -5e17, TickMath.getSqrtPriceAtTick(tickUpper + 120));

        (uint256 beforeClose0, uint256 beforeClose1) = _balances(alice);
        vm.prank(alice);
        positions.close(id);
        (uint256 afterClose0, uint256 afterClose1) = _balances(alice);

        uint256 returned0 = afterClose0 - beforeClose0;
        uint256 returned1 = afterClose1 - beforeClose1;

        assertEq(returned0, 0, "a fully crossed upper range should hold no currency0");
        assertGt(returned1, 0, "should have converted into currency1");

        // Realised price, scaled by 1e18.
        uint256 realised = (returned1 * 1e18) / principal0;

        // The geometric mean of the range's bounds is the price at its midpoint tick.
        uint256 geometricMean = _priceAtTickX18((tickLower + tickUpper) / 2);

        // ...and the fee premium on top: geometricMean / (1 - fee).
        uint256 withFee = (geometricMean * 1e6) / (1e6 - STATIC_FEE);

        assertGt(realised, geometricMean, "fees must make the ladder beat its own average price");
        assertApproxEqRel(realised, withFee, 0.0002e18, "realised price should be geometric mean plus the fee");

        // State the premium in its own right, so a change in fee handling fails loudly here.
        uint256 premiumBps = ((realised - geometricMean) * 1e6) / geometricMean;
        assertApproxEqAbs(premiumBps, 3009, 2, "premium should be fee/(1-fee) = 0.3009% at a 0.30% pool");

        assertTrue(positions.getPosition(id).closed);
    }

    /// @notice An untouched range closes back into exactly what funded it (minus rounding dust).
    function test_close_uncrossedRange_returnsPrincipal() public {
        (uint256 before0,) = _balances(alice);

        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);
        vm.prank(alice);
        positions.close(id);

        (uint256 after0,) = _balances(alice);
        assertApproxEqAbs(after0, before0, 2, "principal should round-trip within dust");
    }

    // ------------------------------------------------------------ custody and access control

    /// @notice A keeper may close a position — that is the automation — but the proceeds go to the
    ///         position's owner, never to the caller. This is the property that makes it safe to run
    ///         an automated keeper against user funds.
    function test_keeperCanClose_butProceedsGoToOwner() public {
        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);

        (uint256 keeperBefore0,) = _balances(keeper);
        (uint256 aliceBefore0,) = _balances(alice);

        vm.prank(keeper);
        positions.close(id);

        (uint256 keeperAfter0,) = _balances(keeper);
        (uint256 aliceAfter0,) = _balances(alice);

        assertEq(keeperAfter0, keeperBefore0, "keeper must not receive proceeds");
        assertGt(aliceAfter0, aliceBefore0, "owner receives proceeds");
    }

    function test_close_revertsForStranger() public {
        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);

        vm.prank(bob);
        vm.expectRevert(BarkerV4Positions.NotAuthorized.selector);
        positions.close(id);
    }

    function test_close_revertsWhenAlreadyClosed() public {
        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);
        vm.prank(alice);
        positions.close(id);

        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.PositionAlreadyClosed.selector);
        positions.close(id);
    }

    function test_revokedKeeperCannotClose() public {
        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);

        vm.prank(governance);
        positions.setKeeper(keeper, false);

        vm.prank(keeper);
        vm.expectRevert(BarkerV4Positions.NotAuthorized.selector);
        positions.close(id);
    }

    // ------------------------------------------------------------ fees

    function test_collect_sweepsFeesToOwnerWithoutClosing() public {
        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);

        // Move price into the range so the position is active and earns, then back out.
        vm.prank(bob);
        swapper.swap(key, false, -1e17, TickMath.getSqrtPriceAtTick(900));
        vm.prank(bob);
        swapper.swap(key, true, -1e17, TickMath.getSqrtPriceAtTick(0));

        (uint256 before0, uint256 before1) = _balances(alice);
        vm.prank(alice);
        (uint256 fee0, uint256 fee1) = positions.collect(id);
        (uint256 after0, uint256 after1) = _balances(alice);

        assertGt(fee0 + fee1, 0, "trading through the range should have earned fees");
        assertEq(after0 - before0, fee0);
        assertEq(after1 - before1, fee1);
        assertFalse(positions.getPosition(id).closed, "collect must not close the position");
        assertEq(positions.getPosition(id).liquidity, 1e18, "principal untouched");
    }

    // ------------------------------------------------------------ pausing

    /// @notice Pausing stops new risk from being opened but must never trap existing capital.
    function test_paused_blocksOpenButNotClose() public {
        vm.prank(alice);
        uint256 id = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);

        vm.prank(governance);
        positions.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.Paused.selector);
        positions.open(key, 1200, 1800, 1e18, BarkerV4Positions.Side.Upper);

        vm.prank(alice);
        positions.close(id); // must still work
        assertTrue(positions.getPosition(id).closed);
    }

    function test_setPaused_revertsForNonGovernance() public {
        vm.prank(alice);
        vm.expectRevert(BarkerV4Positions.NotGovernance.selector);
        positions.setPaused(true);
    }

    // ------------------------------------------------------------ registry

    /// @notice Two positions on the same range must not share PoolManager accounting.
    function test_positionsOnSameRangeAreIndependent() public {
        vm.prank(alice);
        uint256 idA = positions.open(key, 600, 1200, 1e18, BarkerV4Positions.Side.Upper);
        vm.prank(bob);
        uint256 idB = positions.open(key, 600, 1200, 2e18, BarkerV4Positions.Side.Upper);

        assertTrue(positions.saltFor(idA) != positions.saltFor(idB), "salts must differ");

        (uint256 bobBefore0,) = _balances(bob);
        vm.prank(alice);
        positions.close(idA);
        (uint256 bobAfter0,) = _balances(bob);

        assertEq(bobAfter0, bobBefore0, "closing one position must not pay out the other");
        assertEq(positions.getPosition(idB).liquidity, 2e18, "the other position survives intact");
    }

    function test_getPosition_revertsForUnknownId() public {
        vm.expectRevert(BarkerV4Positions.UnknownPosition.selector);
        positions.getPosition(999);
    }

    // ------------------------------------------------------------ helpers

    /// @dev Price of currency0 in currency1 at `tick`, scaled by 1e18.
    function _priceAtTickX18(int24 tick) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        return (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192;
    }
}
