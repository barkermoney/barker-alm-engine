// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-07, ETHOnline 2026. New file.

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
import { YieldBackedSettlement } from "../src/YieldBackedSettlement.sol";
import { TokenMock, ThrottledVaultMock } from "./mocks/Mocks.sol";

/// @notice Real fills through an unmodified SwapVM router, settled against vaults by the
///   `IMakerHooks` pair: redeem-on-fill on the way out, redeposit-on-receive on the way in.
///
/// The guard suites established that the *quote* never exceeds the vault position. This suite is
/// the other half of the thesis: when the fill lands, the maker's wallet may hold nothing at all —
/// settlement pulls exactly what the fill needs out of the vault, hands SwapVM its transfer, and
/// puts the taker's payment back to work, all inside the swap transaction.
contract YieldBackedSettlementOnSwapVMTest is Test {
    SwapVMRouter internal router;
    YieldBackedSolvencyGuard internal guard;
    YieldBackedSettlement internal settlement;

    TokenMock internal usdc; // paid out; backed by vaultOut
    TokenMock internal usdt; // taken in; swept into vaultIn
    ThrottledVaultMock internal vaultOut;
    ThrottledVaultMock internal vaultIn;

    address internal maker;
    uint256 internal makerKey;
    address internal taker = makeAddr("taker");

    uint256 internal constant RESERVE = 1_000_000e6;
    uint256 internal constant BACKING = 500_000e6;
    uint256 internal constant SWAP_IN = 100_000e6;

    function setUp() public {
        (maker, makerKey) = makeAddrAndKey("maker");

        router = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");
        guard = new YieldBackedSolvencyGuard();
        settlement = new YieldBackedSettlement(address(router));

        usdc = new TokenMock("USD Coin", "USDC", 6);
        usdt = new TokenMock("Tether USD", "USDT", 6);
        vaultOut = new ThrottledVaultMock(IERC20(address(usdc)));
        vaultIn = new ThrottledVaultMock(IERC20(address(usdt)));

        // Everything the maker holds goes into the payout-side vault: the wallet starts at zero,
        // which is the configuration a yield-backed maker actually runs in.
        usdc.mint(maker, BACKING);
        vm.startPrank(maker);
        usdc.approve(address(vaultOut), BACKING);
        vaultOut.deposit(BACKING, maker);

        // The full allowance set documented on the settlement contract:
        usdc.approve(address(router), type(uint256).max); // 1. payout side, for the swap itself
        vaultOut.approve(address(settlement), type(uint256).max); // 2. shares, for redeem-on-fill
        usdt.approve(address(settlement), type(uint256).max); // 3. inbound side, for redeposit
        vm.stopPrank();

        usdt.mint(taker, 10 * SWAP_IN);
        vm.prank(taker);
        usdt.approve(address(router), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // order assembly
    // ---------------------------------------------------------------------

    function _pair() internal view returns (address tokenA, address tokenB, bool isAToB) {
        return address(usdc) < address(usdt)
            ? (address(usdc), address(usdt), false) // B→A pays out USDC
            : (address(usdt), address(usdc), true); // A→B pays out USDC
    }

    function _reserveArgs() internal view returns (uint256 first, uint256 second) {
        return address(usdt) < address(usdc) ? (RESERVE, RESERVE) : (RESERVE, RESERVE);
    }

    function _order(uint256 bufferBps) internal view returns (ISwapVM.Order memory) {
        (uint256 first, uint256 second) = _reserveArgs();
        (address tokenA, address tokenB,) = _pair();

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
                hasPostTransferInHook: true,
                hasPreTransferOutHook: true,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(settlement),
                postTransferInData: abi.encode(address(vaultIn), bufferBps),
                preTransferOutTarget: address(settlement),
                preTransferOutData: abi.encode(address(vaultOut), bufferBps),
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: bytes.concat(
                    StaticBalances.build(first, second),
                    Extruction.build(address(guard), abi.encodePacked(address(vaultOut))),
                    XYCSwap.build(),
                    Salt.build(1)
                )
            })
        );
    }

    function _signedTakerData(ISwapVM.Order memory order, bool isExactIn) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, router.hash(order));
        (,, bool isAToB) = _pair();
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: isExactIn,
                shouldUnwrapWeth: false,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: true, // pay first, then the hooks settle the payout
                useTransferFromAndAquaPush: false,
                isAToB: isAToB,
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
                signature: abi.encodePacked(r, s, v)
            })
        );
    }

    function _swap(uint256 bufferBps, uint256 amountIn) internal returns (uint256, uint256) {
        ISwapVM.Order memory order = _order(bufferBps);
        // Taker data is built before the prank: `_signedTakerData` staticcalls `router.hash`,
        // which would otherwise consume the prank and leave `swap` coming from the test contract.
        bytes memory takerData = _signedTakerData(order, true);
        vm.prank(taker);
        (uint256 inAmt, uint256 outAmt,) = router.swap(order, amountIn, takerData);
        return (inAmt, outAmt);
    }

    // ---------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------

    /// @notice The headline: wallet at zero, every dollar in the vault — and the fill settles.
    function test_fillSettlesFromAnEmptyWalletByRedeemingJustInTime() public {
        assertEq(usdc.balanceOf(maker), 0, "precondition: nothing loose");

        (, uint256 amountOut) = _swap(0, SWAP_IN);

        assertGt(amountOut, 0, "fill should clear");
        assertEq(usdc.balanceOf(taker), amountOut, "taker paid out of the vault, just in time");
        assertEq(usdc.balanceOf(maker), 0, "buffer 0: nothing left loose after the fill");
        assertEq(vaultOut.maxWithdraw(maker), BACKING - amountOut, "payout came out of the position");
    }

    /// @notice The taker's payment is earning yield before the transaction ends.
    function test_inboundPaymentIsRedepositedInTheSameTransaction() public {
        (uint256 amountIn,) = _swap(0, SWAP_IN);

        assertEq(usdt.balanceOf(maker), 0, "buffer 0: nothing sits idle");
        assertEq(vaultIn.maxWithdraw(maker), amountIn, "the whole payment went into the inbound vault");
    }

    /// @notice The quoted amount and the settled amount are the same number.
    /// @dev Guard and settlement compose: what the guard promises, the hooks deliver. This is the
    ///   invariant the two contracts exist to hold up jointly.
    function test_quoteAndSettlementAgree() public {
        ISwapVM.Order memory order = _order(0);
        (, uint256 quoted,) = router.quote(order, SWAP_IN, _signedTakerData(order, true));

        (, uint256 settled) = _swap(0, SWAP_IN);

        assertEq(settled, quoted, "a quote the guard passed is a quote settlement can honour");
    }

    /// @notice A non-zero buffer is refilled by the same redemption that covers the fill.
    function test_bufferIsToppedUpAlongsideTheFill() public {
        uint256 bufferBps = 1_000; // keep 10% of the position liquid

        (, uint256 amountOut) = _swap(bufferBps, SWAP_IN);

        uint256 position = usdc.balanceOf(maker) + vaultOut.maxWithdraw(maker);
        uint256 target = position * bufferBps / 10_000;
        assertEq(usdc.balanceOf(maker), target, "one redemption served the fill and the buffer");
        assertEq(position, BACKING - amountOut, "no value appeared or vanished");
    }

    /// @notice Fills inside the buffer never touch the vault: that is what the buffer buys.
    /// @dev The float has to already stand at or above the buffer target — a float *below* target
    ///   gets topped up by the same redemption that serves the fill, which is maintenance working
    ///   as designed, not a failure of the buffer.
    function test_smallFillInsideTheBufferSkipsTheVault() public {
        usdc.mint(maker, 100_000e6); // float well above the 10% target of a ~600k position
        uint256 vaultBefore = vaultOut.maxWithdraw(maker);

        uint256 tinyFill = 1_000e6;
        (, uint256 amountOut) = _swap(1_000, tinyFill);

        assertGt(amountOut, 0);
        assertEq(vaultOut.maxWithdraw(maker), vaultBefore, "payout served entirely from the float");
    }

    /// @notice The inbound sweep respects the buffer too: only the excess goes back to the vault.
    function test_inboundSweepLeavesTheBufferLiquid() public {
        uint256 bufferBps = 2_000;

        (uint256 amountIn,) = _swap(bufferBps, SWAP_IN);

        uint256 position = usdt.balanceOf(maker) + vaultIn.maxWithdraw(maker);
        uint256 target = position * bufferBps / 10_000;
        assertEq(usdt.balanceOf(maker), target, "buffer stays loose");
        assertEq(position, amountIn, "everything else is deposited");
    }

    /// @notice Nobody but the router can drive the hooks, even with valid-looking arguments.
    function test_hooksRejectAnyCallerButTheRouter() public {
        bytes memory makerData = abi.encode(address(vaultOut), uint256(0));

        vm.expectRevert(abi.encodeWithSelector(YieldBackedSettlement.NotRouter.selector, address(this)));
        settlement.preTransferOut(maker, taker, address(usdt), address(usdc), 0, 1e6, bytes32(0), makerData, "");

        vm.expectRevert(abi.encodeWithSelector(YieldBackedSettlement.NotRouter.selector, address(this)));
        settlement.postTransferIn(maker, taker, address(usdt), address(usdc), 1e6, 0, 0, bytes32(0), makerData, "");
    }

    /// @notice A hook shipped pointing at a vault for the wrong asset fails by name on first touch.
    function test_wrongVaultInHookDataFailsLoudly() public {
        ISwapVM.Order memory order = _order(0);
        // Rebuild with the vaults swapped: the outbound hook now names the USDT vault.
        order = _orderWithSwappedVaults();

        bytes memory takerData = _signedTakerData(order, true);
        vm.prank(taker);
        // The taker pays first, so the inbound hook — now pointing at the USDC vault while
        // receiving USDT — is the first place the misconfiguration can be observed.
        vm.expectRevert(
            abi.encodeWithSelector(YieldBackedSettlement.VaultAssetMismatch.selector, address(vaultOut), address(usdt))
        );
        router.swap(order, SWAP_IN, takerData);
    }

    /// @notice Settlement is the last line, not the first: an unguarded over-quote dies in the
    ///   hook with the real reason, instead of as a bare transfer revert.
    function test_unbackedFillFailsByNameNotAsAnAllowanceRevert() public {
        // Throttle the vault after the maker shipped: quote-time guard would catch this, so ship
        // without the guard to simulate a maker that quoted depth it cannot deliver.
        ISwapVM.Order memory order = _orderWithoutGuard();
        vaultOut.setLiquidityCap(1_000e6);

        bytes memory takerData = _signedTakerData(order, true);
        vm.prank(taker);
        // XYC on 1M reserves quotes ~90.9k out for 100k in; only 1k is redeemable.
        vm.expectRevert(
            abi.encodeWithSelector(YieldBackedSettlement.UnbackedFill.selector, 90_909_090_909, 1_000e6)
        );
        router.swap(order, SWAP_IN, takerData);
    }

    // ---------------------------------------------------------------------
    // order variants for the failure tests
    // ---------------------------------------------------------------------

    function _orderWithSwappedVaults() internal view returns (ISwapVM.Order memory order) {
        order = _order(0);
        // Rebuilding through the library keeps traits consistent; only the hook data differs.
        (uint256 first, uint256 second) = _reserveArgs();
        (address tokenA, address tokenB,) = _pair();
        order = MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                tokenA: tokenA,
                tokenB: tokenB,
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: false,
                allowZeroAmountIn: false,
                receiver: address(0),
                hasPreTransferInHook: false,
                hasPostTransferInHook: true,
                hasPreTransferOutHook: true,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(settlement),
                postTransferInData: abi.encode(address(vaultOut), uint256(0)),
                preTransferOutTarget: address(settlement),
                preTransferOutData: abi.encode(address(vaultIn), uint256(0)),
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: bytes.concat(
                    StaticBalances.build(first, second),
                    Extruction.build(address(guard), abi.encodePacked(address(vaultOut))),
                    XYCSwap.build(),
                    Salt.build(1)
                )
            })
        );
    }

    function _orderWithoutGuard() internal view returns (ISwapVM.Order memory) {
        (uint256 first, uint256 second) = _reserveArgs();
        (address tokenA, address tokenB,) = _pair();
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
                hasPostTransferInHook: true,
                hasPreTransferOutHook: true,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(settlement),
                postTransferInData: abi.encode(address(vaultIn), uint256(0)),
                preTransferOutTarget: address(settlement),
                preTransferOutData: abi.encode(address(vaultOut), uint256(0)),
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: bytes.concat(StaticBalances.build(first, second), XYCSwap.build(), Salt.build(1))
            })
        );
    }
}
