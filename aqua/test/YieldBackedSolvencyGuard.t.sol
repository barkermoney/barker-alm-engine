// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-05, ETHOnline 2026. New file.

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SwapQuery, SwapRegisters } from "swap-vm/src/libs/VM.sol";

import { YieldBackedSolvencyGuard } from "../src/YieldBackedSolvencyGuard.sol";
import { TokenMock, ThrottledVaultMock, WrongAssetVaultMock, NotAVault } from "./mocks/Mocks.sol";

contract YieldBackedSolvencyGuardTest is Test {
    YieldBackedSolvencyGuard internal guard;

    TokenMock internal usdc;
    TokenMock internal usdt;
    ThrottledVaultMock internal vault;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal router = makeAddr("router");

    uint256 internal constant VIRTUAL_RESERVE = 1_000_000e6;

    function setUp() public {
        guard = new YieldBackedSolvencyGuard();

        usdc = new TokenMock("USD Coin", "USDC", 6);
        usdt = new TokenMock("Tether USD", "USDT", 6);
        vault = new ThrottledVaultMock(IERC20(address(usdc)));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _fundVault(uint256 assets) internal {
        usdc.mint(maker, assets);
        vm.startPrank(maker);
        usdc.approve(address(vault), assets);
        vault.deposit(assets, maker);
        vm.stopPrank();
    }

    function _approveRouter(uint256 amount) internal {
        vm.prank(maker);
        usdc.approve(router, amount);
    }

    function _query(bool isExactIn) internal view returns (SwapQuery memory) {
        return SwapQuery({
            orderHash: keccak256("strategy"),
            maker: maker,
            taker: taker,
            tokenIn: address(usdt),
            tokenOut: address(usdc),
            isExactIn: isExactIn
        });
    }

    function _registers(uint256 balanceOut) internal pure returns (SwapRegisters memory) {
        return SwapRegisters({ balanceIn: VIRTUAL_RESERVE, balanceOut: balanceOut, amountIn: 0, amountOut: 0 });
    }

    function _args(address vault_) internal pure returns (bytes memory) {
        return abi.encodePacked(vault_);
    }

    /// @dev Calls the guard the way SwapVM does — as the router, so `msg.sender` carries the
    ///   spender identity the allowance is read against.
    function _run(
        SwapQuery memory query,
        SwapRegisters memory registers,
        bytes memory args
    ) internal returns (uint256 nextPC, uint256 chopped, SwapRegisters memory updated) {
        vm.prank(router);
        return guard.extruction(true, 7, query, registers, args, "");
    }

    // ---------------------------------------------------------------------
    // capping
    // ---------------------------------------------------------------------

    function test_capsReserveToRedeemableVaultAssets() public {
        _fundVault(250_000e6);
        _approveRouter(type(uint256).max);

        (,, SwapRegisters memory updated) = _run(_query(true), _registers(VIRTUAL_RESERVE), _args(address(vault)));

        assertEq(updated.balanceOut, 250_000e6, "reserve should collapse to what the vault can redeem");
    }

    function test_countsLooseInventoryAlongsideTheVault() public {
        _fundVault(100_000e6);
        usdc.mint(maker, 40_000e6); // buffer held outside the vault
        _approveRouter(type(uint256).max);

        (,, SwapRegisters memory updated) = _run(_query(true), _registers(VIRTUAL_RESERVE), _args(address(vault)));

        assertEq(updated.balanceOut, 140_000e6, "liquid buffer and vault position both back the quote");
    }

    function test_allowanceBindsWhenItIsTheTighterLimit() public {
        _fundVault(500_000e6);
        _approveRouter(60_000e6);

        (,, SwapRegisters memory updated) = _run(_query(true), _registers(VIRTUAL_RESERVE), _args(address(vault)));

        assertEq(updated.balanceOut, 60_000e6, "an unapproved vault position cannot be paid out");
    }

    function test_vaultLiquidityCrunchTightensTheQuote() public {
        _fundVault(500_000e6);
        _approveRouter(type(uint256).max);
        vault.setLiquidityCap(30_000e6); // vault assets deployed and not instantly redeemable

        (,, SwapRegisters memory updated) = _run(_query(true), _registers(VIRTUAL_RESERVE), _args(address(vault)));

        assertEq(updated.balanceOut, 30_000e6, "share value is not the same thing as redeemable value");
    }

    function test_neverRaisesAReserveTheStrategyDidNotAuthorise() public {
        _fundVault(900_000e6);
        _approveRouter(type(uint256).max);

        uint256 modestReserve = 25_000e6;
        (,, SwapRegisters memory updated) = _run(_query(true), _registers(modestReserve), _args(address(vault)));

        assertEq(updated.balanceOut, modestReserve, "the guard is a ceiling, never a floor");
    }

    function test_withoutAVaultOnlyLooseInventoryBacksTheQuote() public {
        _fundVault(400_000e6); // vault position exists but is not declared in the strategy
        usdc.mint(maker, 12_000e6);
        _approveRouter(type(uint256).max);

        (,, SwapRegisters memory updated) = _run(_query(true), _registers(VIRTUAL_RESERVE), "");

        assertEq(updated.balanceOut, 12_000e6, "an undeclared vault does not back anything");
    }

    function test_vaultForAnotherAssetDoesNotBackThisSide() public {
        WrongAssetVaultMock wrongVault = new WrongAssetVaultMock(IERC20(address(usdt)));
        usdc.mint(maker, 5_000e6);
        _approveRouter(type(uint256).max);

        (,, SwapRegisters memory updated) = _run(_query(true), _registers(VIRTUAL_RESERVE), _args(address(wrongVault)));

        assertEq(updated.balanceOut, 5_000e6, "a USDT vault cannot settle a USDC leg");
    }

    function test_registersOtherThanBalanceOutAreLeftAlone() public {
        _fundVault(10_000e6);
        _approveRouter(type(uint256).max);

        SwapRegisters memory incoming =
            SwapRegisters({ balanceIn: 777e6, balanceOut: VIRTUAL_RESERVE, amountIn: 55e6, amountOut: 0 });

        (uint256 nextPC, uint256 chopped, SwapRegisters memory updated) =
            _run(_query(true), incoming, _args(address(vault)));

        assertEq(updated.balanceIn, 777e6, "inbound reserve untouched");
        assertEq(updated.amountIn, 55e6, "taker-specified amount untouched");
        assertEq(nextPC, 7, "the guard does not branch");
        assertEq(chopped, 0, "the guard consumes no taker arguments");
    }

    // ---------------------------------------------------------------------
    // exact-output
    // ---------------------------------------------------------------------

    function test_exactOutBeyondSolvencyRevertsByName() public {
        _fundVault(20_000e6);
        _approveRouter(type(uint256).max);

        SwapRegisters memory incoming = SwapRegisters({
            balanceIn: VIRTUAL_RESERVE,
            balanceOut: VIRTUAL_RESERVE,
            amountIn: 0,
            amountOut: 20_000e6 + 1
        });

        vm.expectRevert(
            abi.encodeWithSelector(YieldBackedSolvencyGuard.QuoteExceedsSolvency.selector, 20_000e6 + 1, 20_000e6)
        );
        _run(_query(false), incoming, _args(address(vault)));
    }

    function test_exactOutWithinSolvencyPasses() public {
        _fundVault(20_000e6);
        _approveRouter(type(uint256).max);

        SwapRegisters memory incoming =
            SwapRegisters({ balanceIn: VIRTUAL_RESERVE, balanceOut: VIRTUAL_RESERVE, amountIn: 0, amountOut: 20_000e6 });

        (,, SwapRegisters memory updated) = _run(_query(false), incoming, _args(address(vault)));

        assertEq(updated.amountOut, 20_000e6, "the requested output survives");
        assertEq(updated.balanceOut, 20_000e6, "and the reserve is still capped");
    }

    // ---------------------------------------------------------------------
    // malformed input
    // ---------------------------------------------------------------------

    function test_malformedArgsRejected() public {
        _approveRouter(type(uint256).max);

        bytes memory tooShort = hex"deadbeef";
        vm.expectRevert(abi.encodeWithSelector(YieldBackedSolvencyGuard.MalformedGuardArgs.selector, 4));
        _run(_query(true), _registers(VIRTUAL_RESERVE), tooShort);
    }

    function test_nonVaultAddressRevertsRatherThanDegrading() public {
        NotAVault impostor = new NotAVault();
        usdc.mint(maker, 1_000e6);
        _approveRouter(type(uint256).max);

        vm.expectRevert();
        _run(_query(true), _registers(VIRTUAL_RESERVE), _args(address(impostor)));
    }

    // ---------------------------------------------------------------------
    // quote / swap consistency
    // ---------------------------------------------------------------------

    /// @notice The quote path and the swap path must agree, or takers get quoted fills that fail.
    /// @dev SwapVM reaches this target through `IStaticExtruction` while quoting (`STATICCALL`) and
    ///   through `IExtruction` while swapping (`CALL`). Both interfaces declare the same signature,
    ///   so they share one selector and resolve to the same function. This asserts that identity
    ///   holds at the ABI level rather than trusting it.
    function test_quoteAndSwapPathsShareOneImplementation() public {
        _fundVault(77_000e6);
        _approveRouter(type(uint256).max);

        bytes memory callData = abi.encodeWithSelector(
            YieldBackedSolvencyGuard.extruction.selector,
            false,
            uint256(7),
            _query(true),
            _registers(VIRTUAL_RESERVE),
            _args(address(vault)),
            bytes("")
        );

        vm.prank(router);
        (bool staticOk, bytes memory staticResult) = address(guard).staticcall(callData);

        vm.prank(router);
        (bool callOk, bytes memory callResult) = address(guard).call(callData);

        assertTrue(staticOk, "quote path reverted");
        assertTrue(callOk, "swap path reverted");
        assertEq(keccak256(staticResult), keccak256(callResult), "quote and swap must not diverge");

        (,, SwapRegisters memory updated) = abi.decode(staticResult, (uint256, uint256, SwapRegisters));
        assertEq(updated.balanceOut, 77_000e6);
    }

    // ---------------------------------------------------------------------
    // sizing helper
    // ---------------------------------------------------------------------

    function testFuzz_deliverableIsTheMinimumOfItsThreeInputs(
        uint128 vaultAssets,
        uint128 looseInventory,
        uint128 allowance
    ) public {
        vm.assume(vaultAssets > 0);
        _fundVault(vaultAssets);
        usdc.mint(maker, looseInventory);
        _approveRouter(allowance);

        uint256 backing = uint256(vaultAssets) + uint256(looseInventory);
        uint256 expected = backing < allowance ? backing : allowance;

        assertEq(guard.deliverableAmount(maker, address(usdc), address(vault), router), expected);
    }
}
