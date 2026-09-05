# Uniswap v4 integration feedback

*A running log of what building on Uniswap v4 actually felt like, written as it happened rather than reconstructed at submission time. Newest entries at the bottom. Rough edges are recorded even when the fix was easy — the point is the developer experience, not a bug report.*

**Context:** we are building a single-sided concentrated liquidity manager with a custom hook (dynamic fee), targeting Circle's Arc chain. Uniswap v4 is the execution primitive, not a bolt-on. Our comparison baseline is Uniswap v3, which we shipped against previously.

---

## Pre-hackathon probe (Aug 31 – Sep 2, 2026)

Findings from the feasibility probe in [`research/arc-probe/`](research/arc-probe/). Recorded here because they are genuine v4 integration experience, and flagged as pre-event so the timeline is honest.

### 1. `amountSpecified` sign convention is inverted vs. v3 — and it is silent

In v4, a **negative** `amountSpecified` means *exact input*. In v3 it was the opposite (positive = exact input). Nothing warns you: you get a swap that executes in the wrong direction of intent and looks superficially plausible. This cost us a debugging cycle. A named constant or a typed wrapper (`ExactIn(uint256)` / `ExactOut(uint256)`) in the core types would have made this unmissable.

### 2. `PoolOperation.sol` moved, and pinned tags disagree with deployed code

`ModifyLiquidityParams` and `SwapParams` now live in `v4-core/src/types/PoolOperation.sol`, having moved out of `IPoolManager`. Deployed PoolManagers we tested against tracked `v4-core` HEAD, not the most recent tag — so cloning at a tag gave us ABI mismatches that surfaced only as decode failures at runtime. **What we did:** clone `v4-core` at HEAD. **What would have helped:** PoolManager exposing a version identifier on-chain, so integrators can align their ABI to the deployment they are actually talking to instead of guessing.

### 3. Hook address mining is a real onboarding step and deserves first-class tooling

Permission flags live in the low bits of the hook *address*, so deploying a hook means CREATE2 salt mining. This is elegant, and it is also the single biggest "wait, what?" moment for a newcomer. We wrote our own miner ([`MineHook.s.sol`](research/arc-probe/script/MineHook.s.sol)) for flags `0x3000`. A canonical `forge script` helper shipped in `v4-periphery` — "give me flags, get a salt" — would remove a genuine barrier for first-time hook authors.

### 4. You can integrate without `v4-periphery`, and that is a real strength

A **~90-line** helper was enough for the full lifecycle: `unlock` → `unlockCallback` routing to `modifyLiquidity` / `swap`, plus `sync` / `settle` / `take` accounting. No periphery dependency, liquidity computed off-chain. For a team that wants tight control over accounting this is a much better story than v3's, where NonfungiblePositionManager was effectively mandatory. Worth documenting as a supported path rather than leaving people to discover it.

### 5. Dynamic fees: the flag/initialization ordering is easy to get wrong, and fails quietly

Setting `fee = 0x800000` (the dynamic-fee sentinel) in the `PoolKey` and then calling `updateDynamicLPFee` from `afterInitialize` works — we verified `lpFee = 10000` reading back from `slot0`. But if the sentinel and the hook permission flags disagree, you get a pool that silently behaves as a static-fee pool. There is no revert. A check at initialize time (dynamic-fee sentinel set but hook lacks the corresponding permission → revert) would convert a silent misconfiguration into a loud one.

### 6. `sqrtPriceLimitX96` is optional in the API and mandatory in practice

Swapping into a thin or empty range without a price limit pushes the pool to the extreme tick and effectively poisons it. We did this to one of our own test pools and had to rebuild it. Setting the limit just outside the target range is the correct pattern and worked exactly as intended (price stopped precisely at the limit). This is documented, but it reads as an advanced option rather than the safety rail it actually is.

### 7. One-sided positions behave exactly as the math says — no surprises

Minting a one-sided range above spot took only `token0` and zero `token1`; a swap crossing the range returned the quote asset at the geometric mean of the range (measured **+8.46%** on a `+5.25% … +11.76%` range). Textbook. This is the primitive our whole product rests on, and it needed no special handling.

---

## Hackathon build log (Sep 4 – Sep 12, 2026)

*(entries added as the Arc leg is built)*

### Sep 4 — setup

- Repo scaffolded, probe committed as documented pre-existing work.

---

## Summary for the Uniswap Foundation

*(to be filled in before submission — condensed version of the above, plus the answer to "what would have saved us the most time")*

This document is also submitted, by link, through the [Uniswap Developer Feedback Form](https://developers.uniswap.org/hackathon-feedback).
