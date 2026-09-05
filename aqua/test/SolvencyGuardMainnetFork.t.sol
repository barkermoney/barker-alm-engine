// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-05, ETHOnline 2026. New file.

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

/// @notice The guard on an Ethereum mainnet fork, against Steakhouse's live steakUSDC vault and
///   real USDC, with unmodified SwapVM as the execution engine.
///
/// @dev **Why the router is deployed here rather than called at its canonical address.** SwapVM's
///   README points integrators at `0x1111...0De`, which is live on this fork — `AQUA()` answers
///   with the mainnet Aqua ledger. But the deployment predates the current repository: the
///   `quote((address,uint256,bytes),uint256,bytes)` selector this codebase generates, `0xb7ebf0c5`,
///   does not appear anywhere in its bytecode, so a call built from HEAD dies in ~339 gas with no
///   return data at all. `test_canonicalDeploymentHasDriftedFromHead` pins that fact down.
///
///   So this suite deploys the router from unmodified upstream source, wired to the real mainnet
///   Aqua ledger, and keeps everything else on the fork genuine. 1inch's brief permits exactly
///   this: official contracts, redeployed, demonstrated on a local fork.
///
/// @dev Requires `ETHEREUM_RPC_URL`. Without it the suite skips rather than fails, so an offline
///   run stays green and honest about what it did not check.
contract SolvencyGuardMainnetForkTest is Test {
    /// @dev Canonical SwapVM per the upstream README — live, but on an older ABI. See the contract
    ///   doc above.
    address internal constant CANONICAL_SWAP_VM = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev The mainnet Aqua ledger, read off the canonical deployment's `AQUA()`.
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    /// @dev steakUSDC — Steakhouse Financial's MetaMorpho vault, USDC denominated.
    address internal constant STEAK_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    ISwapVM internal swapVM;
    IERC4626 internal vault = IERC4626(STEAK_USDC);

    YieldBackedSolvencyGuard internal guard;

    address internal maker;
    address internal taker = makeAddr("taker");

    uint256 internal constant RESERVE = 10_000_000e6; // virtual reserves, both sides
    uint256 internal constant SWAP_IN = 250_000e6;

    bool internal forked;

    function setUp() public {
        try vm.envString("ETHEREUM_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
            forked = true;
        } catch {
            return;
        }

        maker = makeAddr("yield-backed-maker");
        guard = new YieldBackedSolvencyGuard();

        // Unmodified upstream router, aware of the real Aqua ledger on this fork.
        //
        // `SwapVMRouter`, not `AquaSwapVMRouter`, and the reason is structural rather than
        // incidental: the Aqua opcode set has no `StaticBalances`, because on the custodial track
        // reserves come from the ledger's own accounting. A yield-backed maker cannot use that
        // track at all — capital held in the Aqua ledger is capital that has stopped earning. It
        // must sit in the vault and be pulled against an allowance, which is the signature track.
        swapVM = ISwapVM(address(new SwapVMRouter(AQUA, WETH, address(this), "SwapVM", "1.0.0")));
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev Puts `assets` USDC into steakUSDC on the maker's behalf and approves SwapVM to move the
    ///   payout token. Vault shares are never approved to anyone: the guard reads the position, it
    ///   does not need spending rights over it.
    function _backMakerWithVault(uint256 assets) internal returns (uint256 shares) {
        deal(USDC, maker, assets);

        vm.startPrank(maker);
        IERC20(USDC).approve(STEAK_USDC, assets);
        shares = vault.deposit(assets, maker);
        IERC20(USDC).approve(address(swapVM), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev `StaticBalances` assigns its arguments to in/out by token address order. Reserves here
    ///   are symmetric, so that ordering does not change the result — but `MakerTraits` separately
    ///   *requires* `tokenA < tokenB`, which fixes the pair as (USDC, USDT) and therefore makes the
    ///   USDC-out direction B→A rather than A→B.
    function _reserveArgs() internal pure returns (uint256, uint256) {
        return (RESERVE, RESERVE);
    }

    function _order(bool withGuard) internal view returns (ISwapVM.Order memory) {
        (uint256 first, uint256 second) = _reserveArgs();

        bytes memory program = withGuard
            ? bytes.concat(
                StaticBalances.build(first, second),
                Extruction.build(address(guard), abi.encodePacked(STEAK_USDC)),
                XYCSwap.build(),
                Salt.build(1)
            )
            : bytes.concat(StaticBalances.build(first, second), XYCSwap.build(), Salt.build(1));

        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                tokenA: USDC, // MakerTraits requires the pair sorted ascending
                tokenB: USDT,
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
                isAToB: false, // pair is (USDC, USDT), so B→A is USDT in, USDC out
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

    function _xyc(uint256 reserveOut, uint256 amountIn) internal pure returns (uint256) {
        return reserveOut * amountIn / (RESERVE + amountIn);
    }

    // ---------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------

    /// @notice Sanity: the canonical SwapVM is deployed here and the vault is the one we think.
    function test_mainnetFixturesAreWhatTheyClaim() public onlyForked {
        assertGt(CANONICAL_SWAP_VM.code.length, 0, "SwapVM not deployed on this fork");
        assertEq(vault.asset(), USDC, "steakUSDC should be USDC denominated");
        assertGt(vault.totalAssets(), 1_000_000e6, "vault should hold real money");
    }

    /// @notice The canonical deployment is live but no longer speaks this repository's ABI.
    /// @dev Pinned as a test because it is the kind of thing that costs an integrator an afternoon:
    ///   the README gives an address, the address has code, `AQUA()` answers — and then the first
    ///   real call returns empty. Nothing distinguishes "wrong ABI" from "reverted internally"
    ///   except gas: a selector miss falls through the dispatcher and dies immediately.
    ///
    ///   If 1inch redeploys and this test starts failing, that is good news, and the suite should
    ///   move to calling `CANONICAL_SWAP_VM` directly.
    function test_canonicalDeploymentHasDriftedFromHead() public onlyForked {
        _backMakerWithVault(100_000e6);

        bytes memory callData =
            abi.encodeCall(ISwapVM.quote, (_order(true), SWAP_IN, _takerData(true)));

        (bool ok, bytes memory returned) = CANONICAL_SWAP_VM.staticcall(callData);

        assertFalse(ok, "canonical deployment unexpectedly accepted HEAD's quote ABI");
        assertEq(returned.length, 0, "a selector miss returns nothing at all");

        // Same call against the router built from this repository's source.
        (bool okHead,) = address(swapVM).staticcall(callData);
        assertTrue(okHead, "HEAD source should answer its own ABI");
    }

    /// @notice The whole thesis, on mainnet: a maker whose capital is earning yield in steakUSDC
    ///   quotes against that position through 1inch's deployed VM, and never beyond it.
    function test_quoteIsBoundedByTheLiveSteakUsdcPosition() public onlyForked {
        uint256 deposited = 500_000e6;
        _backMakerWithVault(deposited);

        uint256 redeemable = vault.maxWithdraw(maker);
        assertGt(redeemable, 0, "position should be redeemable");

        (, uint256 unguarded,) = swapVM.quote(_order(false), SWAP_IN, _takerData(true));
        (, uint256 guarded,) = swapVM.quote(_order(true), SWAP_IN, _takerData(true));

        assertEq(unguarded, _xyc(RESERVE, SWAP_IN), "unguarded prices against fiction");
        assertEq(guarded, _xyc(redeemable, SWAP_IN), "guarded prices against the vault");

        assertLt(guarded, unguarded, "the guard costs depth");
        assertLe(guarded, redeemable, "and never promises more than the vault returns");

        // Rounding on deposit means redeemable is a hair under the deposit; the guard tracks the
        // vault's answer, not ours, which is the entire point of reading `maxWithdraw` at quote time.
        assertApproxEqAbs(redeemable, deposited, 2, "share rounding should be sub-unit");
    }

    /// @notice The maker holds no loose USDC at all — every dollar is deployed — and still quotes.
    /// @dev This is the configuration a yield-backed maker actually runs in, and the one where an
    ///   unguarded strategy is most dangerous: wallet balance zero, virtual reserves ten million.
    function test_fullyDeployedMakerQuotesFromZeroWalletBalance() public onlyForked {
        _backMakerWithVault(300_000e6);

        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker should hold no idle USDC");

        (, uint256 guarded,) = swapVM.quote(_order(true), SWAP_IN, _takerData(true));

        assertGt(guarded, 0, "a fully deployed maker is still quotable");
        assertLe(guarded, vault.maxWithdraw(maker), "within the redeemable position");
    }

    /// @notice Yield accrual widens quotable depth on its own, with no strategy change.
    /// @dev steakUSDC's share price only moves as Morpho markets accrue, so this warps time rather
    ///   than faking a balance: the position is untouched and the vault revalues it.
    function test_accruedYieldWidensDepthWithoutTouchingTheStrategy() public onlyForked {
        _backMakerWithVault(1_000_000e6);
        ISwapVM.Order memory order = _order(true);

        (, uint256 before,) = swapVM.quote(order, SWAP_IN, _takerData(true));
        uint256 redeemableBefore = vault.maxWithdraw(maker);

        vm.warp(block.timestamp + 90 days);

        uint256 redeemableAfter = vault.maxWithdraw(maker);
        (, uint256 afterAccrual,) = swapVM.quote(order, SWAP_IN, _takerData(true));

        assertGe(redeemableAfter, redeemableBefore, "a lending vault should not lose value over time");
        assertGe(afterAccrual, before, "and depth follows the position");
    }

    /// @notice Exact-output beyond the live position fails by name through the deployed VM.
    function test_exactOutBeyondThePositionRevertsOnMainnet() public onlyForked {
        _backMakerWithVault(100_000e6);

        uint256 redeemable = vault.maxWithdraw(maker);
        uint256 tooMuch = redeemable + 1e6;

        vm.expectRevert(
            abi.encodeWithSelector(YieldBackedSolvencyGuard.QuoteExceedsSolvency.selector, tooMuch, redeemable)
        );
        swapVM.quote(_order(true), tooMuch, _takerData(false));
    }
}
