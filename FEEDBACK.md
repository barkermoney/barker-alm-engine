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

### Sep 4 — setup, position manager, dynamic fee hook

Repo scaffolded, probe committed as documented pre-existing work. Then the first real build: a one-sided position manager over `PoolManager`, and a surge-fee hook. 35 tests, all green. Four new findings.

#### 8. There is no way to read back what LP fee a swap actually paid

This is the one we would most like fixed.

A `beforeSwap` hook can override the LP fee by returning `fee | OVERRIDE_FEE_FLAG`. That override applies to the swap and is then **gone** — it is not written to `slot0`, not included in the `Swap` event, and not retrievable afterwards by any getter we could find. `slot0.lpFee` continues to report the value from the last `updateDynamicLPFee`, which for an override-driven hook is a number no swap ever actually paid.

So there is no way for an integrator, an indexer, a block explorer, or a user to answer "what did that swap cost?" without the hook having had the foresight to emit its own event. We ended up emitting `FeeApplied` purely so our **own tests** could observe our own hook's behaviour — the assertion had nowhere else to read from.

Concretely, the ask: **put the applied LP fee in the `Swap` event.** It already carries `fee`, but that is the pool's stored fee, not the override that was actually charged. Every dynamic-fee pool on v4 is currently unobservable from the outside, and every such hook is independently reinventing the same event to compensate. Analytics on dynamic-fee pools is not going to happen until this is fixed at the core.

#### 9. Dynamic fees interact with exact-input accounting in a way the docs never state

Worth writing down because it turned out to be the single most important number in our product, and we found it by having a test fail rather than by reading anything.

For an exact-input swap the fee is deducted from the input before the price math runs, while the *whole* input still accrues to the liquidity. So a position whose range is fully crossed realises `geometricMean / (1 - fee)`, not `geometricMean`. At a 0.30% pool that is a premium of exactly `0.003 / 0.997 = 0.3009%`.

For us that premium *is* the product: a one-sided range sells across its span at the geometric mean, which is strictly worse than a limit order resting at the top — and the fee premium is the entire reason to use a range anyway. We now assert it to four decimal places. A worked example of fee-versus-price interaction in the dynamic-fee docs would have saved us the detour, and would help anyone reasoning about whether a fee schedule is actually paying for itself.

#### 10. Hook address mining has no home in `v4-core`

Following on from finding 3. We deliberately built without `v4-periphery` (finding 4 — it works well), but `HookMiner` lives in periphery. So a project taking the no-periphery path has to hand-roll salt mining, which is exactly the piece a newcomer is least equipped to write and most dangerous to get subtly wrong.

Suggestion: `HookMiner` is pure address arithmetic with no dependency on periphery's contracts. It belongs in `v4-core`, or in a standalone package, so that "no periphery" and "can deploy a hook" stop being in tension.

We did add one thing that we would recommend to every hook author, and that we did not see in any example: **check your own address in the constructor.**

```solidity
if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != REQUIRED_FLAGS) revert InvalidHookAddress();
```

Without it, a mis-mined salt produces a hook that compiles, deploys, verifies, and is then silently never called by the PoolManager — a pool that looks like it has a fee schedule and does not. That is a very expensive way to find out. This one-liner turns it into a failed deployment.

#### 11. `StateLibrary` attaches to `IPoolManager`, not `PoolManager`

Small, but it cost a compile cycle. `using StateLibrary for IPoolManager` does not apply to a variable typed as the concrete `PoolManager` — natural to do in tests, where you deploy the concrete contract. The error (`Member "getSlot0" not found`) does not hint that the fix is a cast to the interface. Attaching the library to both types, or a note in the library's docs, would remove the papercut.

### Sep 4 (later) — first deployment to a live chain

Both contracts on Arc testnet, and the full take-profit lifecycle in six real transactions. See
[`arc/DEPLOYMENTS.md`](arc/DEPLOYMENTS.md). Two more findings, one of which cost real debugging time.

#### 12. `StateLibrary.getSlot0` is not callable on a deployed PoolManager, and the revert says nothing

Reading a pool's state off-chain is the single most common thing an integrator does, and it is a
trap. `StateLibrary.getSlot0(manager, poolId)` reads like a method on the PoolManager — it is used
that way everywhere in contract code, via `using StateLibrary for IPoolManager`. It is not one.
There is no `getSlot0` selector on the deployed contract; the library computes a storage slot and
reads it through `extsload`.

So `cast call $POOL_MANAGER 'getSlot0(bytes32)' $POOL_ID` returns a bare `execution reverted`, with
nothing pointing at the cause. Every off-chain consumer has to reimplement the slot arithmetic —
`keccak256(poolId . uint256(6))`, then unpack `sqrtPriceX96`, `tick`, `protocolFee` and `lpFee` out
of one word — and `POOLS_SLOT = 6` is an internal detail that can move between versions.

Two things would fix this, either one sufficient: **ship real view functions on the PoolManager**
(`getSlot0`, `getLiquidity`, `getPositionInfo`), or **publish a small off-chain package that does
the slot math**, so that every indexer, dashboard and shell script is not reinventing it from the
library source. Right now the on-chain and off-chain paths to the same state look identical and
behave completely differently.

#### 13. A fully crossed range matches the clean formula to one part in a million — *retracted and corrected*

**This finding originally said the opposite, and it was wrong. The correction is more useful than
the original claim, so it is left in rather than quietly edited.**

The first version reported that a fully crossed range realised **+0.3489%** over its geometric mean
against the clean formula's +0.3009%, and attributed the ~0.048% gap to v4 per-step rounding
resolving in the liquidity provider's favour. That is a plausible sentence. It is also a story
invented to explain a transcription error: the swap and close amounts had both been copied 1,024
raw units (0x400) high.

Re-read from the `Swap` and `PositionClosed` event payloads by a machine instead of by hand
(`keeper/`, added Sep 8), the same on-chain position returns **2.136890 USDC**, and:

| | |
|---|---|
| Realised premium over the range's geometric mean | **+0.3008%** |
| `fee / (1 − fee)` at 0.30% | **+0.3009%** |

Agreement to within one part in a million, with no rounding term needed at all.

**The finding for Uniswap is the meta one.** v4's range math is exact enough that a discrepancy of
five basis points is *always* your own bug — but nothing in the tooling encourages you to believe
that. There is no canonical "what did this position actually realise" reader, so integrators
hand-copy amounts out of block explorers, and a hand-copied number that is nearly right is far more
dangerous than one that is obviously wrong: it survives review, and someone writes a plausible
mechanism to explain it. A first-party position-accounting helper would have prevented both the
error and the four days it survived.

#### 14. `getSlot0` is a library function, and off-chain clients pay for that

`StateLibrary.getSlot0(manager, poolId)` reads like a method on the PoolManager. It is not — it is
a helper that computes `keccak256(abi.encode(poolId, uint256(6)))` and reads it through `extsload`.
Solidity callers never notice, because `using StateLibrary for IPoolManager` makes the call look
native. **Off-chain callers hit a wall**: there is no `getSlot0` in the deployed ABI, so the obvious
`readContract({ functionName: "getSlot0" })` fails, and the error says the function does not exist
rather than "this lives in a library, do the slot arithmetic yourself."

Every off-chain consumer of v4 therefore reimplements the storage layout — pools at slot 6,
`liquidity` at offset 3, position state at offset 6, plus the packed `slot0` word with its
sign-extended `int24` tick. We did it twice, once in bash and once in TypeScript
([`keeper/src/poolState.ts`](keeper/src/poolState.ts)), and both are pinned by tests against a live
Arc pool because getting the sign extension wrong yields a tick of ~16 million rather than an error.

**Ask:** publish the storage layout as a first-class, versioned artifact, or ship a thin read-only
`StateView`-style contract with the getters on it. Today the canonical description of v4's storage
layout is Solidity library source, which is not a format a TypeScript indexer can consume.

#### 15. `getFeeGrowthInside` reads like "fees owed" and is off by 2**128

Our own bug, found on Sep 8 and worth reporting because the shape of it is v4's, not ours. A view
that returned uncollected fees was implemented as:

```solidity
(fee0, fee1) = poolManager.getFeeGrowthInside(id, tickLower, tickUpper);
```

It compiles, returns two plausible `uint256`s, and is meaningless: fee *growth* is a Q128
per-unit-of-liquidity accumulator, while fee *owed* is
`liquidity * (growthInside - growthInsideLast) / 2**128`. The two differ by roughly 38 orders of
magnitude, so the failure is not a rounding error — it is a number with no relationship to
anything, displayed next to a currency symbol.

Nothing in the naming, the return types, or the NatSpec distinguishes them, and the correct
computation needs a *second* call (`getPositionInfo`, for `liquidity` and the `…Last` snapshots)
plus a deliberately wrapping subtraction. The fix and the test that pins it are in
[`arc/src/BarkerV4Positions.sol`](arc/src/BarkerV4Positions.sol) (`feesOwed`) and
[`arc/test/BarkerV4Positions.t.sol`](arc/test/BarkerV4Positions.t.sol)
(`test_feesOwed_matchesWhatCollectPays` — asserting the view against what `collect` actually pays,
which is the only assertion a wrong-but-consistent implementation cannot satisfy).

**Ask:** a `feesOwed(poolId, positionKey)` helper in `StateLibrary`. Everyone building on v4 needs
this number, everyone derives it from the same two calls, and the intermediate value is one an
integrator can plausibly mistake for the answer.

#### 16. A surge-fee hook needs the clock on *both* halves — our own design bug

Found on Sep 8 by our own keeper, on chain, which is the good way to find it. Our dynamic fee hook
charges `baseFee + surge`, where surge accumulates with `|tick moved since the previous swap|` and
decays linearly over `decayBlocks`. On a pool whose previous swap was four days earlier, it applied
**2.46%** (`FeeApplied(fee=24600, surge=21600, tickMove=1080)`) to a routine trade.

The bug is a clean one to name: **the decay is time-aware and the measurement is not.** Stored
surge decays with elapsed blocks, but the new contribution is `|currentTick - lastTick|` with no
reference to how long that took, so 1,080 ticks of drift over four days is charged exactly like
1,080 ticks in one block. Half the mechanism has a clock and the other half does not.

This is not a v4 defect — v4 gave us exactly the primitive we asked for. It is a warning for anyone
writing their first volatility-responsive hook, and it is the kind of thing a "common hook
pitfalls" page in the docs would have caught before it reached a chain. `beforeSwap` fires on swap
boundaries, not on a schedule, so *any* hook state derived from "since last call" is sampling an
interval of unknown length. The fix we intend is to treat an observation older than `decayBlocks` as
no observation at all — re-baseline and charge the base fee — which is what the hook already does
for a pool it has never seen.

---

## Summary for the Uniswap Foundation

*(to be filled in before submission — condensed version of the above, plus the answer to "what would have saved us the most time")*

This document is also submitted, by link, through the [Uniswap Developer Feedback Form](https://developers.uniswap.org/hackathon-feedback).
