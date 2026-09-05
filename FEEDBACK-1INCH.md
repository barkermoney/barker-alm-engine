# SwapVM / Aqua integration feedback

*Written while building, not reconstructed at submission time. Newest entries at the bottom. The counterpart file for Uniswap v4 is [`FEEDBACK.md`](FEEDBACK.md).*

**Context:** we are building a **yield-backed maker** — market-making capital that sits in an ERC-4626 vault earning yield and is redeemed only when a fill demands it. The SwapVM surfaces we use are the `Extruction` opcode (quote-time solvency) and `IMakerHooks` (settlement). Our code lives in [`aqua/`](aqua/) under SwapVM-1.1.

---

## Sep 5, 2026 — the extension points

### 1. Extending SwapVM does not require forking it, and that deserves to be the headline

We came in expecting to fork the opcode table. We did not have to. `Extruction` hands the swap registers to a maker-chosen contract, and `IMakerHooks` brackets both transfers — between them we got quote-time solvency checks and redeem-on-fill settlement without touching a line of upstream source.

This is the single best thing about the architecture and it is undersold. The README describes `Extruction` as "make external calls and execute custom logic during swap computation," which reads like an escape hatch. It is closer to a plugin ABI. Worth a page in `docs/` with a worked example, because the fork-vs-extend question is the first thing anyone integrating has to answer, and getting it wrong costs days.

### 2. `IExtruction` and `IStaticExtruction` share a selector — which is a feature, and is not written down

The two interfaces declare the same name and parameter types, differing only in mutability. Mutability is not part of a function's identity, so **both resolve to one selector**, and a target cannot implement both: `contract G is IExtruction, IStaticExtruction` does not compile.

The consequence is good. Implement only the `view` form and the quote path (`STATICCALL`) and the swap path (`CALL`) land on the same bytecode — quote/swap consistency stops being a discipline the maker has to maintain and becomes a property of the type system. That is a much stronger guarantee than the docs currently claim for themselves.

But the code comment on `Extruction` asks implementers to keep the two modes "deterministic, consistent across quote / swap modes" as though it were their problem, and nothing says the one-function form exists. A first-time implementer will reasonably try to write two functions, hit a confusing compile error, and have to reverse-engineer why. One sentence — *"implement `IStaticExtruction` alone; the swap path reaches the same selector"* — would save that.

### 3. Two independent sort orders, and getting either wrong fails differently

`MakerTraits` requires `tokenA < tokenB` and rejects an unsorted pair with `MakerTraitsTokensNotSorted()` — clear enough. Separately, `StaticBalances` maps its two arguments onto in/out by comparing `tokenIn < tokenOut` at execution time, so which reserve is "A" depends on address order rather than argument order.

Both rules are individually reasonable. Together they mean a strategy author juggles two sortings that look alike and fail differently: the first is a named revert, the second silently swaps your reserves and quotes a wrong but plausible price. With symmetric reserves — the common case while testing — the second is invisible. We hit this and only caught it because our mock token addresses happened to sort the other way in one suite.

Naming the arguments for what they are (`balanceForLowerToken` / `balanceForHigherToken`) would remove the ambiguity at zero cost.

### 4. The canonical deployment has drifted from the repository, and the failure is silent

The README gives `0x111111338c5091E8440b67B168bAe16a668AC0De` as the deployment address across fifteen chains. On Ethereum mainnet that address is live and answers `AQUA()` with `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`. But the `quote((address,uint256,bytes),uint256,bytes)` selector generated from the current repository — `0xb7ebf0c5` — **does not appear in its bytecode**, and a call built from HEAD dies in roughly 339 gas with no return data whatsoever.

Empty revert data is the worst possible signal here. It is indistinguishable from an internal revert, so the integrator's first instinct is to debug their strategy program — which is fine, and takes a while to rule out. The tell is gas: a selector miss falls through the dispatcher immediately.

Three things would each have prevented the detour, in rough order of value:

- a `version()` on the router, so an integrator can check alignment in one call;
- the deployment addresses in the README carrying the tag or commit they were built from;
- publishing the deployed ABI alongside the address.

This is the same failure we hit on Uniswap v4 (see `FEEDBACK.md` §2), which suggests it is a general gap in how AMM protocols publish deployments rather than anything specific to SwapVM.

We pinned the behaviour in a test (`test_canonicalDeploymentHasDriftedFromHead`) so that a future redeploy turns it green and tells us to switch back to calling the canonical address.

### 5. The Aqua opcode set has no `StaticBalances`, and that quietly rules out yield-backed making

`AquaOpcodes` omits `StaticBalances` and `DynamicBalances` — correctly, since on the custodial track reserves come from the Aqua ledger's own accounting. Reaching for it produces `UnknownOpcode(144)`, which is a fine error once you know what it means.

The structural consequence took longer to see, and is the more interesting point: **capital sitting in the Aqua ledger is capital that has stopped earning.** A maker whose backing is an ERC-4626 position cannot use the custodial track at all, because the ledger wants to hold the tokens themselves. Yield-backed making has to run on the signature track, holding the assets in the vault and letting the router pull against an allowance.

We think this is worth stating explicitly in the docs, because the two tracks are presented as an implementation detail of authorisation (`useAquaInsteadOfSignature`) when they are also a decision about *where the capital lives* — and that second consequence is the one that determines whether a whole category of maker is possible.

It also suggests a genuinely interesting extension: an Aqua ledger that can custody ERC-4626 shares and unwrap them on fill would let yield-backed makers onto the custodial track and would, as far as we can tell, be the first AMM where idle depth is not idle. We are not proposing it as a hackathon deliverable — but it is where our build points.

### 6. Quoting zero reverts rather than returning zero

When our guard drives deliverable depth to zero (maker revoked the router's allowance), the curve prices a zero output and SwapVM rejects the fill with `TakerTraitsAmountOutMustBeGreaterThanZero(0)` rather than quoting `0`.

Not a complaint — it is the right behaviour, and it gives yield-backed makers a clean kill switch: revoking one approval takes the maker offline through the protocol's own checks, with no pause flag and no strategy re-ship. Recording it because an aggregator polling `quote` across makers must treat this revert as "no liquidity" rather than as an error, and that distinction is not documented.

---

## Summary for 1inch

The extension points are the right ones and we did not need to fork. Our whole build sits in two contracts hanging off `Extruction` and `IMakerHooks`.

Ranked by what we would fix first:

1. **Publish a `version()` and tie README addresses to a commit** — §4. Silent ABI drift with empty revert data is the costliest thing we hit.
2. **Document the one-function `Extruction` form** — §2. The design is better than the docs claim; say so.
3. **Say where the capital lives when describing the two tracks** — §5. It decides which makers are possible.
4. **Name the `StaticBalances` arguments by token order** — §3. Silent wrong-price on a mistake that is invisible under symmetric reserves.
