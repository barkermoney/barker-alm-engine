// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-05, ETHOnline 2026. New file.

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapVM } from "swap-vm/src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "swap-vm/src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "swap-vm/src/libs/TakerTraits.sol";
import { StaticBalances } from "swap-vm/src/instructions/Balances.sol";
import { XYCSwap } from "swap-vm/src/instructions/XYCSwap.sol";
import { Extruction } from "swap-vm/src/instructions/Extruction.sol";
import { Salt } from "swap-vm/src/instructions/Controls.sol";

import { YieldBackedSolvencyGuard } from "../src/YieldBackedSolvencyGuard.sol";
import { TokenMock, ThrottledVaultMock } from "./mocks/Mocks.sol";

/// @notice The guard running inside an unmodified SwapVM router, reached through the official
///   `Extruction` opcode — not called directly as in the unit tests.
/// @dev The point of this suite is that nothing here is a stand-in: the router, the opcode
///   dispatcher, the reserve instruction and the constant-product curve are all upstream code, and
///   the only Barker contract in the path is the guard the strategy names as an extruction target.
contract SolvencyGuardOnSwapVMTest is Test {
    SwapVMRouter internal router;
    YieldBackedSolvencyGuard internal guard;

    TokenMock internal usdc; // paid out, backed by the vault
    TokenMock internal usdt; // taken in
    ThrottledVaultMock internal vault;

    address internal maker;
    uint256 internal makerKey;
    address internal taker = makeAddr("taker");

    uint256 internal constant RESERVE_IN = 1_000_000e6;
    uint256 internal constant RESERVE_OUT = 1_000_000e6;
    uint256 internal constant SWAP_IN = 100_000e6;

    function setUp() public {
        (maker, makerKey) = makeAddrAndKey("maker");

        router = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");
        guard = new YieldBackedSolvencyGuard();

        usdc = new TokenMock("USD Coin", "USDC", 6);
        usdt = new TokenMock("Tether USD", "USDT", 6);
        vault = new ThrottledVaultMock(IERC20(address(usdc)));
    }

    // ---------------------------------------------------------------------
    // strategy assembly
    // ---------------------------------------------------------------------

    /// @dev Two independent orderings bite here, and mock addresses depend on deploy nonce, so
    ///   neither is assumed. `MakerTraits` requires `tokenA < tokenB`; that determines which
    ///   direction flag yields USDC-out. `StaticBalances` separately maps its two arguments onto
    ///   in/out by the same address comparison.
    function _pair() internal view returns (address tokenA, address tokenB, bool isAToB) {
        return address(usdc) < address(usdt)
            ? (address(usdc), address(usdt), false) // B→A pays out USDC
            : (address(usdt), address(usdc), true); // A→B pays out USDC
    }

    function _reserveArgs() internal view returns (uint256 first, uint256 second) {
        return address(usdt) < address(usdc) ? (RESERVE_IN, RESERVE_OUT) : (RESERVE_OUT, RESERVE_IN);
    }

    function _order(bool withGuard) internal view returns (ISwapVM.Order memory) {
        (uint256 first, uint256 second) = _reserveArgs();
        (address tokenA, address tokenB,) = _pair();

        bytes memory program = withGuard
            ? bytes.concat(
                StaticBalances.build(first, second),
                Extruction.build(address(guard), abi.encodePacked(address(vault))),
                XYCSwap.build(),
                Salt.build(1)
            )
            : bytes.concat(StaticBalances.build(first, second), XYCSwap.build(), Salt.build(1));

        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                tokenA: tokenA,
                tokenB: tokenB,
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: false,
                allowZeroAmountIn: false,
                receiver: address(0),
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: program
            })
        );
    }

    function _takerData(bool isExactIn) internal view returns (bytes memory) {
        (,, bool isAToB) = _pair();
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: isExactIn,
                shouldUnwrapWeth: false,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                isAToB: isAToB, // whichever direction pays out USDC for this deploy order
                allowPartialFill: false,
                threshold: "",
                to: address(0),
                deadline: 0,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }

    function _fundVault(uint256 assets) internal {
        usdc.mint(maker, assets);
        vm.startPrank(maker);
        usdc.approve(address(vault), assets);
        vault.deposit(assets, maker);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Constant product, the same arithmetic the `XYCSwap` opcode performs.
    function _xyc(uint256 reserveOut, uint256 amountIn) internal pure returns (uint256) {
        return reserveOut * amountIn / (RESERVE_IN + amountIn);
    }

    // ---------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------

    /// @notice The headline: the same strategy quotes far less once the guard sees the real backing.
    function test_guardShrinksTheQuoteToWhatTheVaultCanRedeem() public {
        uint256 backing = 200_000e6;
        _fundVault(backing);

        (, uint256 unguarded,) = router.quote(_order(false), SWAP_IN, _takerData(true));
        (, uint256 guarded,) = router.quote(_order(true), SWAP_IN, _takerData(true));

        assertEq(unguarded, _xyc(RESERVE_OUT, SWAP_IN), "unguarded quote prices against virtual reserves");
        assertEq(guarded, _xyc(backing, SWAP_IN), "guarded quote prices against the vault position");

        assertLt(guarded, unguarded, "the guard must cost depth, that is the point");
        assertLe(guarded, backing, "and never quote beyond what can be redeemed");
    }

    /// @notice Without the guard the strategy quotes a fill it cannot settle. With it, it does not.
    /// @dev This is the failure mode the guard exists for. A maker whose capital is earning yield
    ///   has almost nothing loose; shipping virtual reserves that ignore that fact produces quotes
    ///   that die at transfer time, after the taker has already paid for the attempt.
    function test_unguardedStrategyQuotesMoreThanItHoldsAndTheGuardedOneDoesNot() public {
        uint256 backing = 5_000e6; // deliberately thin
        _fundVault(backing);

        (, uint256 unguarded,) = router.quote(_order(false), SWAP_IN, _takerData(true));
        (, uint256 guarded,) = router.quote(_order(true), SWAP_IN, _takerData(true));

        assertGt(unguarded, backing, "unguarded: promises more USDC than the maker can produce");
        assertLe(guarded, backing, "guarded: promises only what it can produce");
    }

    /// @notice A vault liquidity crunch reprices the strategy without anyone re-shipping it.
    /// @dev Strategies are immutable once shipped. Reading solvency at quote time is what lets a
    ///   fixed program track a moving vault position.
    function test_quoteFollowsTheVaultWithoutReshippingTheStrategy() public {
        _fundVault(400_000e6);
        ISwapVM.Order memory order = _order(true);

        (, uint256 before,) = router.quote(order, SWAP_IN, _takerData(true));

        vault.setLiquidityCap(50_000e6); // markets fully utilised; redemptions throttled
        (, uint256 afterCrunch,) = router.quote(order, SWAP_IN, _takerData(true));

        assertEq(before, _xyc(400_000e6, SWAP_IN));
        assertEq(afterCrunch, _xyc(50_000e6, SWAP_IN));
        assertLt(afterCrunch, before, "same bytecode, tighter quote");
    }

    /// @notice Revoking the router's allowance takes the maker offline through the same path.
    /// @dev The guard drives deliverable depth to zero, the curve then prices a zero output, and
    ///   SwapVM's own `TakerTraits` check rejects the fill before it can be signed for. Revoking an
    ///   approval is therefore a complete kill switch for a yield-backed maker — no separate pause
    ///   flag, no strategy re-ship, and it works even if the maker has lost access to whatever
    ///   off-chain system was quoting for it.
    function test_allowanceRevocationTakesTheMakerOffline() public {
        _fundVault(400_000e6);

        vm.prank(maker);
        usdc.approve(address(router), 0);

        vm.expectRevert(abi.encodeWithSignature("TakerTraitsAmountOutMustBeGreaterThanZero(uint256)", 0));
        router.quote(_order(true), SWAP_IN, _takerData(true));
    }

    /// @notice Loose inventory and vault position are both real backing, and both are counted.
    function test_looseBufferAddsToQuotableDepth() public {
        _fundVault(100_000e6);

        (, uint256 vaultOnly,) = router.quote(_order(true), SWAP_IN, _takerData(true));

        usdc.mint(maker, 50_000e6); // operator tops up the hot buffer
        (, uint256 withBuffer,) = router.quote(_order(true), SWAP_IN, _takerData(true));

        assertEq(vaultOnly, _xyc(100_000e6, SWAP_IN));
        assertEq(withBuffer, _xyc(150_000e6, SWAP_IN));
    }

    /// @notice An exact-output request beyond the backing fails by name, through the router.
    function test_exactOutBeyondBackingRevertsThroughTheRouter() public {
        _fundVault(10_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(YieldBackedSolvencyGuard.QuoteExceedsSolvency.selector, 10_001e6, 10_000e6)
        );
        router.quote(_order(true), 10_001e6, _takerData(false));
    }

    /// @notice Quoting is a `STATICCALL`; the guard must survive it.
    /// @dev A guard that wrote storage would compile, pass a swap-path test, and revert every quote
    ///   in production. The unit suite asserts the two paths return identical bytes; this asserts
    ///   the static path works at all when reached through the real router.
    function test_guardSurvivesTheStaticQuotePath() public {
        _fundVault(75_000e6);

        (uint256 amountIn, uint256 amountOut,) = router.quote(_order(true), SWAP_IN, _takerData(true));

        assertEq(amountIn, SWAP_IN);
        assertEq(amountOut, _xyc(75_000e6, SWAP_IN));
        assertGt(amountOut, 0);
    }
}
