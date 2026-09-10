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

#### 8. What LP fee did a swap actually pay? — *retracted and corrected Sep 10*

> **What we originally wrote here, on Sep 4, and billed as "the one we would most like fixed":** that
> a `beforeSwap` fee override "is not written to `slot0`, not included in the `Swap` event, and not
> retrievable afterwards", that the `Swap` event's `fee` field is "the pool's stored fee, not the
> override that was actually charged", and that every dynamic-fee pool on v4 is therefore
> unobservable from outside.

**The middle claim is false, and our own indexer is what showed it.** On Sep 8 our hook overrode a
swap's LP fee to 2.46%. The `Swap` event the PoolManager emitted for that swap —
[`0x59d12358…`](https://testnet.arcscan.app/tx/0x59d12358cf619de41eb99659eb17f6a37bf382824d026217e3c164aa9d1e035c),
block 61,111,138 — carries **`fee = 24600`**: the override, not the stored 3000. The source agrees:
`Pool.swap` computes `swapFee` from `params.lpFeeOverride` when the override flag is set and from
`slot0` only otherwise, and `PoolManager.swap` emits exactly that `swapFee`. Anyone indexing v4
`Swap` events can answer "what did that swap cost?" for any dynamic-fee pool, with no help from the
hook. We found this on Sep 10 while building the dashboard's fee log, which now reads the fee from
the PoolManager's event rather than from ours.

What remains true is narrow: the override is not persisted to `slot0`, so `slot0.lpFee` on an
override-driven pool is a base rate rather than a price anyone paid — which is by design — and the
`Swap` event's `fee` is the total swap fee, LP and protocol together, so the LP share has to be
separated out when a protocol fee is switched on. Our hook's own `FeeApplied` event is still worth
having, but for the *breakdown* (base, surge, the tick move that caused it), not because the fee is
otherwise invisible.

**How the error happened, since that is the useful part.** We wrote the entry from the Foundry test
suite, where we had asserted against our hook's own event and never looked at the PoolManager's.
The conclusion was drawn from where we had looked, not from where the data was. It then sat at the
top of this file for six days, through two further sessions of work on the same hook, because
nothing we built had any reason to read the `Swap` event's `fee` field — until something did.
Same lesson as §13: the only reliable reviewer for a claim about on-chain data is a program that
reads the on-chain data.

**The DX point that survives:** the override documentation could say, next to `OVERRIDE_FEE_FLAG`,
that the applied fee is reported in `Swap.fee`. We are hook authors who went looking for exactly
that sentence and, not finding it, assumed the opposite.

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

#### 16. A surge-fee hook must date a move to when it happened — our own design bug, *diagnosis corrected Sep 10*

Found on Sep 8 by our own keeper, on chain, which is the good way to find it. Our dynamic fee hook
charges `baseFee + surge`, where surge accumulates with `|tick moved since the previous swap|` and
decays linearly over `decayBlocks`. On a pool whose previous swap was four days earlier, it applied
**2.46%** (`FeeApplied(fee=24600, surge=21600, tickMove=1080)`) to a routine trade.

> **What we originally wrote here, on Sep 8:** that "the decay is time-aware and the measurement is
> not", that "1,080 ticks of drift over four days is charged exactly like 1,080 ticks in one block",
> that because `beforeSwap` fires on swap boundaries "any hook state derived from 'since last call'
> is sampling an interval of unknown length", and that the fix was to treat an observation older
> than `decayBlocks` as no observation at all.

**There was no drift.** A v4 pool's price is moved only by swaps on that pool, and every swap on a
pool with our hook passes through `beforeSwap`, which rewrites the observation. So
`currentTick − lastTick` is never movement over an interval of unknown length: it is **exactly the
price impact of the previous swap**. Our own indexer's event log shows it — the pool has two swaps.
The Sep 4 lifecycle swap (block 60,522,820) took the tick from −368,460 to −367,380; the Sep 8 swap
(block 61,111,138) started at −367,380 and was charged for −367,380 − (−368,460) = **1,080 ticks**.
Nothing moved in the four days between. The hook billed one trader for another trader's price
impact, 588,318 blocks after it happened.

So the defect is narrower than we said, and the fix is different. The move happened in
`lastBlock` — the same block the stored surge is dated to — so both belong on the same clock:
`surge = decay(min(stored + |move| × surgePerTick, maxFee), block − lastBlock)`. That is a
reordering, not a new mechanism. The re-baseline fix we proposed would have been worse: it charges
a move in full one block before the window closes and nothing one block after. The corrected hook
is on branch [`fix/fee-hook-clock`](https://github.com/barkermoney/barker-alm-engine/tree/fix/fee-hook-clock),
with a replay of the Sep 8 incident on the deployed parameters as a regression test; it is **not
deployed** — see [`docs/schedule.md`](docs/schedule.md), decision 0.

**How the error happened.** "The previous observation is four days old" slid into "the price
drifted for four days" without our asking what could have moved the price in between. On a v4 pool
with a swap hook the answer is *nothing but the swaps the hook already saw*. Same lesson as §8 and
§13: the event log answered the question the moment we asked it.

**The DX point, which is better than the one we first made.** A hook with `BEFORE_SWAP` gets
something unusual and valuable: between two of its calls, the pool's price has moved by exactly one
swap, at a known block. Volatility measured this way is exact, not sampled. A "hook patterns" page
could say so in one sentence — and add the corollary that bit us: the move you measure in
`beforeSwap` belongs to the *previous* swap, and should be dated to it.

---

## Summary for the Uniswap Foundation

*(to be filled in before submission — condensed version of the above, plus the answer to "what would have saved us the most time")*

This document is also submitted, by link, through the [Uniswap Developer Feedback Form](https://developers.uniswap.org/hackathon-feedback).
