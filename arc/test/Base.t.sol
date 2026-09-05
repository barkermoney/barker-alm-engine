// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BarkerV4Positions} from "../src/BarkerV4Positions.sol";
import {TestSwapper} from "./utils/TestSwapper.sol";

/// @notice Shared fixture: a real v4-core PoolManager and two mock ERC-20s.
///
/// @dev These tests deploy an actual PoolManager rather than mocking it. That is deliberate — the
///      properties we care about (is the position genuinely one-sided? does a crossed range realise
///      the geometric mean?) are properties of Uniswap's math, and a mock would let us assert our
///      own assumptions back to ourselves.
///
///      Mock ERC-20s rather than Arc's USDC, also deliberate: Arc's USDC is a native precompile that
///      Foundry's EVM does not implement, so a test touching it reverts with `StackUnderflow`. The
///      real USDC paths are exercised on-chain with `cast`, never in simulation.
abstract contract Base is Test {
    PoolManager internal manager;
    TestSwapper internal swapper;
    BarkerV4Positions internal positions;

    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    address internal governance = makeAddr("governance");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant STATIC_FEE = 3000;

    function setUpBase() internal {
        manager = new PoolManager(address(this));
        swapper = new TestSwapper(IPoolManager(address(manager)));
        positions = new BarkerV4Positions(IPoolManager(address(manager)), governance);

        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        vm.prank(governance);
        positions.setKeeper(keeper, true);

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        token0.mint(who, 1e30);
        token1.mint(who, 1e30);
        vm.startPrank(who);
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        token0.approve(address(swapper), type(uint256).max);
        token1.approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    function _poolKey(IHooks hooks, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: TICK_SPACING, hooks: hooks});
    }

    /// @dev Initialize at tick 0, i.e. a 1:1 price. Keeps the arithmetic in the assertions legible.
    function _initPool(PoolKey memory key) internal returns (int24 tick) {
        tick = manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function _balances(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = token0.balanceOf(who);
        b1 = token1.balanceOf(who);
    }
}
