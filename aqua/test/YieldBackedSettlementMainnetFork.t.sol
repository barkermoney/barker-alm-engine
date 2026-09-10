// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-07, ETHOnline 2026. New file.

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

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

/// @notice The whole engine, end to end, on an Ethereum mainnet fork: real USDC, real USDT, and
///   Steakhouse's live steakUSDC vault — guard bounding the quote, hooks settling the fill,
///   unmodified SwapVM in the middle.
///
/// The two directions demonstrate the two halves of settlement against a production vault:
///
/// - **USDT → USDC** (redeem-on-fill): the maker's USDC lives entirely in steakUSDC. The fill's
///   payout is withdrawn from the vault by `preTransferOut` inside the swap transaction.
///
/// - **USDC → USDT** (redeposit-on-receive): the taker pays USDC, and `postTransferIn` deposits
///   it into steakUSDC before the transaction ends — inbound inventory starts earning immediately.
///
/// @dev Same fork discipline as `SolvencyGuardMainnetForkTest`: the router is deployed from
///   unmodified upstream source because the canonical mainnet deployment predates this ABI (that
///   drift is pinned by a test over there), and the suite skips rather than fails without
///   `ETHEREUM_RPC_URL`.
contract YieldBackedSettlementMainnetForkTest is Test {
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant STEAK_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    SwapVMRouter internal router;
    IERC4626 internal vault = IERC4626(STEAK_USDC);
    YieldBackedSolvencyGuard internal guard;
    YieldBackedSettlement internal settlement;

    address internal maker;
    uint256 internal makerKey;
    address internal taker = makeAddr("taker");

    uint256 internal constant RESERVE = 10_000_000e6;
    uint256 internal constant BACKING = 500_000e6;
    uint256 internal constant SWAP_IN = 100_000e6;

    bool internal forked;

    function setUp() public {
        try vm.envString("ETHEREUM_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
            forked = true;
        } catch {
            return;
        }

        (maker, makerKey) = makeAddrAndKey("yield-backed-maker");
        guard = new YieldBackedSolvencyGuard();
        router = new SwapVMRouter(AQUA, WETH, address(this), "SwapVM", "1.0.0");
        settlement = new YieldBackedSettlement(address(router));

        // The maker's entire USDC stack goes into steakUSDC; the wallet starts empty.
        deal(USDC, maker, BACKING);
        vm.startPrank(maker);
        IERC20(USDC).approve(STEAK_USDC, type(uint256).max);
        vault.deposit(BACKING, maker);

        // The documented allowance set, both directions:
        IERC20(USDC).approve(address(router), type(uint256).max); // payout, USDC-out direction
        IERC20(vault).approve(address(settlement), type(uint256).max); // shares, for redeem-on-fill
        IERC20(USDC).approve(address(settlement), type(uint256).max); // inbound sweep, USDC-in direction
        SafeUsdt.approve(USDT, address(router), type(uint256).max); // payout, USDT-out direction
        vm.stopPrank();
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ---------------------------------------------------------------------
    // order assembly — pair is (USDC, USDT), sorted as MakerTraits requires
    // ---------------------------------------------------------------------

    /// @param usdcOut true for the USDT→USDC direction (redeem-on-fill), false for USDC→USDT
    ///   (redeposit-on-receive)
    function _order(bool usdcOut) internal view returns (ISwapVM.Order memory) {
        return _order(usdcOut, true);
    }

    /// @param guarded false drops the solvency guard from the program — the strategy a maker would
    ///   ship without it, used only to show what that strategy would have promised
    function _order(bool usdcOut, bool guarded) internal view returns (ISwapVM.Order memory) {
        // The guard's vault argument only matters on the USDC-out side; paying out USDT the maker
        // quotes against loose inventory, which the guard reads with no vault attached.
        bytes memory guard_ = !guarded
            ? bytes("")
            : usdcOut
                ? Extruction.build(address(guard), abi.encodePacked(STEAK_USDC))
                : Extruction.build(address(guard), "");
        bytes memory program = bytes.concat(StaticBalances.build(RESERVE, RESERVE), guard_, XYCSwap.build(), Salt.build(1));

        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                tokenA: USDC,
                tokenB: USDT,
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: false,
                allowZeroAmountIn: false,
                receiver: address(0),
                hasPreTransferInHook: false,
                // USDC-in direction: sweep the taker's payment into steakUSDC.
                hasPostTransferInHook: !usdcOut,
                // USDC-out direction: pull the payout from steakUSDC just in time.
                hasPreTransferOutHook: usdcOut,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: usdcOut ? address(0) : address(settlement),
                postTransferInData: usdcOut ? bytes("") : abi.encode(STEAK_USDC, uint256(0)),
                preTransferOutTarget: usdcOut ? address(settlement) : address(0),
                preTransferOutData: usdcOut ? abi.encode(STEAK_USDC, uint256(0)) : bytes(""),
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: program
            })
        );
    }

    function _signedTakerData(ISwapVM.Order memory order, bool usdcOut) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, router.hash(order));
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: true,
                shouldUnwrapWeth: false,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: true,
                useTransferFromAndAquaPush: false,
                isAToB: !usdcOut, // pair (USDC, USDT): A→B pays out USDT, B→A pays out USDC
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

    function _swap(bool usdcOut, uint256 amountIn) internal returns (uint256, uint256) {
        ISwapVM.Order memory order = _order(usdcOut);
        bytes memory takerData = _signedTakerData(order, usdcOut);
        vm.prank(taker);
        (uint256 inAmt, uint256 outAmt,) = router.swap(order, amountIn, takerData);
        return (inAmt, outAmt);
    }

    // ---------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------

    /// @notice Redeem-on-fill against the live vault: wallet empty, position in steakUSDC, and the
    ///   taker still walks away with USDC inside one transaction.
    function test_fillIsPaidOutOfLiveSteakUsdc() public onlyForked {
        deal(USDT, taker, SWAP_IN);
        vm.prank(taker);
        SafeUsdt.approve(USDT, address(router), SWAP_IN);

        assertEq(IERC20(USDC).balanceOf(maker), 0, "precondition: no loose USDC");
        uint256 positionBefore = vault.maxWithdraw(maker);

        (uint256 amountIn, uint256 amountOut) = _swap(true, SWAP_IN);

        assertEq(amountIn, SWAP_IN);
        assertGt(amountOut, 0);
        assertEq(IERC20(USDC).balanceOf(taker), amountOut, "taker paid in real USDC");
        assertEq(IERC20(USDT).balanceOf(maker), amountIn, "maker received the USDT");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "buffer 0: nothing left loose");
        // MetaMorpho rounds share burns in the vault's favour; the position shrinks by the payout
        // plus at most a dust of rounding.
        assertApproxEqAbs(positionBefore - vault.maxWithdraw(maker), amountOut, 2, "payout came from the vault");
    }

    /// @notice Redeposit-on-receive against the live vault: the taker's USDC is inside steakUSDC —
    ///   earning — before the swap transaction ends.
    function test_inboundUsdcIsEarningInSteakUsdcBeforeTheTransactionEnds() public onlyForked {
        deal(USDT, maker, 200_000e6); // loose USDT inventory backs the payout side
        deal(USDC, taker, SWAP_IN);
        vm.prank(taker);
        IERC20(USDC).approve(address(router), SWAP_IN);

        uint256 positionBefore = vault.maxWithdraw(maker);

        (uint256 amountIn, uint256 amountOut) = _swap(false, SWAP_IN);

        assertGt(amountOut, 0);
        assertEq(IERC20(USDT).balanceOf(taker), amountOut, "taker paid in real USDT");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "no USDC left idle in the wallet");
        assertApproxEqAbs(
            vault.maxWithdraw(maker) - positionBefore, amountIn, 2, "the payment is already in the vault"
        );
    }

    /// @notice Guard and settlement agree on the fork too: the quoted amount is the settled amount.
    function test_quoteAndSettlementAgreeOnTheFork() public onlyForked {
        deal(USDT, taker, SWAP_IN);
        vm.prank(taker);
        SafeUsdt.approve(USDT, address(router), SWAP_IN);

        ISwapVM.Order memory order = _order(true);
        bytes memory takerData = _signedTakerData(order, true);
        (, uint256 quoted,) = router.quote(order, SWAP_IN, takerData);

        vm.prank(taker);
        (, uint256 settled,) = router.swap(order, SWAP_IN, takerData);

        assertEq(settled, quoted, "what the guard quoted, the hooks settled");
        assertLe(quoted, BACKING, "and it never exceeded the backing");
    }

    /// @notice A round trip: sell USDC depth out of the vault, take USDC back in — the position
    ///   breathes with flow and no capital ever sits idle between fills.
    function test_roundTripLeavesNoIdleCapital() public onlyForked {
        deal(USDT, taker, SWAP_IN);
        deal(USDC, taker, SWAP_IN);
        vm.startPrank(taker);
        SafeUsdt.approve(USDT, address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), SWAP_IN);
        vm.stopPrank();

        // Leg 1: taker buys USDC out of the vault.
        (, uint256 usdcOutAmount) = _swap(true, SWAP_IN);

        // Leg 2: taker sells USDC back; it goes straight into the vault. The maker now holds
        // loose USDT from leg 1, which backs this direction's payout.
        (uint256 usdcInAmount,) = _swap(false, SWAP_IN);

        assertGt(usdcOutAmount, 0);
        assertGt(usdcInAmount, 0);
        assertEq(IERC20(USDC).balanceOf(maker), 0, "after both legs, no idle USDC anywhere");
        // Net position change = inflow − outflow, up to one unit of vault rounding per leg.
        uint256 expected = BACKING - usdcOutAmount + usdcInAmount;
        assertApproxEqAbs(vault.maxWithdraw(maker), expected, 4, "the vault absorbed the net flow");
    }

    // ---------------------------------------------------------------------
    // dashboard trace
    // ---------------------------------------------------------------------

    /// @notice The whole story in five steps, recorded for the dashboard: what an unguarded
    ///   strategy would promise, what the guarded one quotes, a fill paid out of the vault, a fill
    ///   paid into it, and a month of yield widening depth with nobody touching the strategy.
    /// @dev Asserts the same invariants as the tests above, so the trace cannot drift into
    ///   something the suite does not also prove. Writes `app/public/aqua-fork-trace.json` only
    ///   when `RECORD_TRACE=true`, so an ordinary run never rewrites a committed file:
    ///
    ///     RECORD_TRACE=true ETHEREUM_RPC_URL=… forge test --match-test test_recordDashboardTrace
    function test_recordDashboardTrace() public onlyForked {
        uint256 bigAsk = 1_000_000e6; // twice the backing
        uint256 fill = 10_000e6;
        // The USDT side is backed by loose inventory: this demo pairs one yield-bearing side with
        // one plain side, which is also the realistic first deployment.
        deal(USDT, maker, 500_000e6);
        deal(USDT, taker, fill);
        deal(USDC, taker, fill);
        vm.startPrank(taker);
        SafeUsdt.approve(USDT, address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), fill);
        vm.stopPrank();

        string memory steps = _step(
            "deposit",
            "Maker puts 500,000 USDC into steakUSDC and keeps none of it loose. The USDT side is 500,000 USDT of plain inventory.",
            0,
            0
        );

        // 1. The same strategy, quoted with and without the guard, for twice the backing.
        (, uint256 unguarded,) = router.quote(_order(true, false), bigAsk, _signedTakerData(_order(true, false), true));
        (, uint256 guarded,) = router.quote(_order(true), bigAsk, _signedTakerData(_order(true), true));
        assertGt(unguarded, vault.maxWithdraw(maker), "unguarded promises more than the vault holds");
        assertLe(guarded, vault.maxWithdraw(maker), "guarded never does");
        steps = string.concat(
            steps,
            ",",
            _step("quote", "Taker asks to sell 1,000,000 USDT for USDC: twice what backs the maker.", bigAsk, guarded)
        );
        string memory quoteNote = string.concat(
            "\"unguardedQuote\":\"", vm.toString(unguarded), "\",\"guardedQuote\":\"", vm.toString(guarded), "\""
        );

        // 2. Redeem-on-fill: a real fill, paid out of steakUSDC inside the swap.
        (, uint256 out1) = _swap(true, fill);
        assertEq(IERC20(USDC).balanceOf(maker), 0, "nothing left idle after the payout");
        steps = string.concat(
            steps,
            ",",
            _step("fill-out", "Taker sells 10,000 USDT. The USDC payout is redeemed from steakUSDC inside the swap.", fill, out1)
        );

        // 3. Redeposit-on-receive: the taker's USDC is in the vault before the transaction ends.
        (, uint256 out2) = _swap(false, fill);
        assertEq(IERC20(USDC).balanceOf(maker), 0, "inbound USDC went straight to the vault");
        steps = string.concat(
            steps,
            ",",
            _step("fill-in", "Taker sells 10,000 USDC back. It is deposited into steakUSDC in the same transaction.", fill, out2)
        );

        // 4. Time passes; the vault accrues; quotable depth follows without a strategy change.
        uint256 before = vault.maxWithdraw(maker);
        vm.warp(block.timestamp + 30 days);
        assertGe(vault.maxWithdraw(maker), before, "a lending vault should not lose value over time");
        (, uint256 guardedLater,) = router.quote(_order(true), bigAsk, _signedTakerData(_order(true), true));
        steps = string.concat(
            steps,
            ",",
            _step("accrue", "30 days pass. The position earns steakUSDC yield and quotable depth widens with it.", bigAsk, guardedLater)
        );

        string memory json = string.concat(
            "{\"recordedAtBlock\":", vm.toString(block.number),
            ",\"chainId\":1,\"vault\":\"", vm.toString(STEAK_USDC),
            "\",\"virtualReserve\":\"", vm.toString(RESERVE),
            "\",\"backing\":\"", vm.toString(BACKING),
            "\",", quoteNote,
            ",\"steps\":[", steps, "]}"
        );

        if (vm.envOr("RECORD_TRACE", false)) {
            vm.writeFile("../app/public/aqua-fork-trace.json", json);
        }
    }

    /// @dev One step of the trace, with the maker's balances read at the moment it is recorded.
    function _step(string memory id, string memory text, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "{\"id\":\"", id,
            "\",\"text\":\"", text,
            "\",\"block\":", vm.toString(block.number),
            ",\"timestamp\":", vm.toString(block.timestamp),
            ",\"amountIn\":\"", vm.toString(amountIn),
            "\",\"amountOut\":\"", vm.toString(amountOut),
            "\",\"makerWalletUsdc\":\"", vm.toString(IERC20(USDC).balanceOf(maker)),
            "\",\"makerWalletUsdt\":\"", vm.toString(IERC20(USDT).balanceOf(maker)),
            "\",\"makerVaultUsdc\":\"", vm.toString(vault.maxWithdraw(maker)),
            "\",\"makerShares\":\"", vm.toString(IERC20(STEAK_USDC).balanceOf(maker)),
            "\"}"
        );
    }
}

/// @dev Mainnet USDT's `approve` returns nothing, which reverts through the `IERC20` interface's
///   expected `bool`. A raw call sidesteps the ABI mismatch without dragging a full SafeERC20
///   dependency into test code.
library SafeUsdt {
    function approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok, "USDT approve failed");
    }
}
