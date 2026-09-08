# Keeper — event indexer and unattended position keeper

MIT licensed. See the repository root [`LICENSE`](../LICENSE).

This is the off-chain half of the Arc leg: it watches Uniswap v4 pools, rebuilds the position
registry from events, and closes one-sided ladders on its own when they have finished converting.

**It closed a real position on Arc testnet, unattended, on Sep 8, 2026** — the run log is at the
bottom of this file and the transactions are in [`../arc/DEPLOYMENTS.md`](../arc/DEPLOYMENTS.md).

```bash
npm install
npm run index     # pull every event into ./data
npm run status    # live view: tick, conversion %, fees owed, per position
npm run once      # one keeper pass; read-only unless KEEPER_PRIVATE_KEY is set
npm run run       # the unattended loop
npm test          # 15 tests, no node required
```

## What decides an exit

A one-sided range is an execution primitive, not a yield position, so it has a definite end: the
moment the ladder has fully converted. For an `Upper` position — funded in the base asset, placed
above spot, selling into strength — that is `tick >= tickUpper`. Below that the ladder is still
working, and closing early leaves the unconverted remainder to be sold at market instead of at the
ladder's own prices. `Lower` is the mirror, at `tick < tickLower`; the asymmetry is v4's, since a
range is active on `[tickLower, tickUpper)`.

The whole decision lives in [`src/policy.ts`](src/policy.ts) as one pure function of a snapshot.
No clients, no clock, no I/O — so the rule a reviewer reads is literally the rule that runs, and
the interesting behaviour is testable without a chain.

### Confirmations, and why a keeper should hesitate

The exit condition must hold for **three consecutive observations** before the keeper acts. A single
block that wicks past the top of the range and comes straight back is not a converted ladder, and
closing on it realises the wick instead of the trend. One observation back inside the range resets
the count to zero — the counter measures consecutive evidence, not cumulative.

A restart also starts the count over, deliberately: a keeper coming back from a crash should
re-observe the market rather than act on a stale belief about it.

### What the keeper is not allowed to do

`close` and `collect` take no recipient argument. They always pay the position's own owner, so the
blast radius of a stolen keeper key is *positions get closed earlier than their owner wanted*, into
that owner's own wallet. Nothing can be redirected and nothing can be drained.

That property is only real if the automation actually runs on its own key, which is why the Sep 8
run used a freshly generated keeper address rather than the position owner's — a demo sharing one
key would look identical and prove nothing. The keeper also refuses to transact below a gas floor,
so it cannot strand itself half way through an exit, and it **gates the action rather than the
observation**: an unauthorised or unfunded keeper keeps watching and keeps reporting, because a
keeper that goes quiet when it cannot act is a keeper that misses the exit and calls it fine.

## The indexer

`Initialize`, `ModifyLiquidity` and `Swap` on the PoolManager are the only record of what happened
to a v4 pool. There is no per-pair contract to query — v4 keeps every pool inside one singleton —
so reconstructing history means those three events plus `extsload`. [`src/indexer.ts`](src/indexer.ts)
folds them, together with the position registry's own events, into the pool and position summaries
the dashboard reads.

Two properties of the store ([`src/store.ts`](src/store.ts)) are worth more than its storage engine,
and both are scars from a production incident on another Barker service where a replayed window
double-counted hourly volume:

- **Events are keyed by `(blockNumber, logIndex)` and de-duplicated on insert**, so re-indexing a
  range already indexed is a no-op.
- **The cursor advances only in the same atomic write as the data it describes** (temp file, then
  rename), so a reader never sees a cursor ahead of its events, and a crash between the two costs a
  redundant fetch rather than a wrong number.

The failure being designed out is not "the file is corrupt". It is "the numbers are plausible and
wrong" — which is exactly what happened by hand to the figures this indexer was first pointed at,
see [`../FEEDBACK.md`](../FEEDBACK.md) §13.

## Three things that cost time, for anyone doing this on v4 or on Arc

1. **`StateLibrary.getSlot0` is not a method on the PoolManager.** It is a library helper that
   computes `keccak256(abi.encode(poolId, 6))` and reads it through `extsload`. Off chain you do the
   slot arithmetic yourself ([`src/poolState.ts`](src/poolState.ts)), including sign-extending the
   packed `int24` tick — get that wrong and you read a tick of ~16 million rather than an error.
2. **`getFeeGrowthInside` is not "fees owed"**, it is a Q128 per-unit-of-liquidity accumulator, and
   mistaking one for the other is a ~2^128 error that type-checks. Fixed in the registry contract on
   Sep 8; see `FEEDBACK.md` §15.
3. **Arc's public node caps `eth_getLogs` at somewhere between 25k and 30k blocks** (`-32012`), and
   `cast logs` hides this by paginating internally — so the ceiling is invisible until you write
   your own client. The indexer halves its page size on rejection rather than hard-coding a limit a
   node operator is free to change.

## Configuration

Everything is environment variables; addresses default to the pinned values in
[`../docs/environment.md`](../docs/environment.md).

| Variable | Default | Meaning |
|---|---|---|
| `ARC_RPC` | `https://rpc.testnet.arc.io` | Node |
| `POSITIONS` | `0x8ba4bFeC…a4Bb` | Position registry |
| `POOL_MANAGER` | `0x2756F3F7…240A` | Uniswap v4 PoolManager |
| `HOOK` | unset | Dynamic fee hook, if its events should be indexed |
| `START_BLOCK` | `60522409` | Registry deployment block |
| `KEEPER_CONFIRMATIONS` | `3` | Consecutive confirmations before acting |
| `MIN_FEE_SWEEP` | `0` (off) | Sweep fees once owed exceeds this, in raw units |
| `MIN_GAS_BALANCE` | `0.5 USDC` | Refuse to transact below this |
| `KEEPER_POLL_MS` | `5000` | Poll interval |
| `KEEPER_PRIVATE_KEY` | unset | Signing key. **Read-only commands do not need it**, and it must not be the position owner's. |

No private key is committed, and none is read from a file in this repository.

## The Sep 8 run, unedited

Position #2 was opened at tick −367380 with a range at `[−367320, −367140)` — `+0.60% … +2.43%`
above spot — and the keeper was started with no further human involvement. A separate wallet then
pushed the price through the range. Nobody told the keeper to do anything.

```
18:15:08 keeper starting · poll 5000ms · 3 confirmations required
18:15:08 keeper 0xA980cCF5224baA2E2AeC59C6022a57433645D33d
18:15:12 #2 HOLD — still working: tick -367380 inside [-367320, -367140)
18:15:22 #2 HOLD — still working: tick -367380 inside [-367320, -367140)
18:15:32 #2 HOLD — still working: tick -367380 inside [-367320, -367140)
18:15:41 #2 HOLD — still working: tick -367380 inside [-367320, -367140)
         ← a separate wallet swaps 2.4 USDC in, driving price to tick -367080
18:15:51 #2 ARM   — converted at tick -367080 (1/3 confirmations)
18:16:00 #2 ARM   — converted at tick -367080 (2/3 confirmations)
18:16:12 #2 CLOSE — fully converted: tick -367080 >= -367140, held for 3 observations
                    · tx 0xbc03cc81944930febc3811292958cf1bc078c08bc3b14f5a58a0083a931c269b
18:16:21 no open positions
```

Those four `HOLD` lines say "inside" about a tick that is in fact *below* the range. The verdict was
right and the sentence was wrong — a position not yet reached and a position being filled are both
"working", and the log conflated them. Fixed after this run, so the wording differs from what
`src/policy.ts` prints today; the log above is reproduced as it was actually emitted rather than
tidied up to match.

The close transaction was **sent by** `0xA980cCF5…D33d`, the keeper. The 2.312322 USDC it released
went **to** `0x7ad19e19…06C8E`, the position's owner. Afterwards the keeper held 0.997406 USDC of
its original 1.0 and zero BPROBE: it paid 0.002594 USDC of gas and received nothing. That is the
custody claim, on chain, rather than in a comment.

One honest note on the economics of that run: the position realised **+4.07%** against spot on a
range topping out at +2.43%, which is impossible for a ladder alone. The excess is fee revenue — the
dynamic fee hook charged the incoming swap **2.46%** rather than the base 0.30%, because it was the
first swap in four days and the hook bills price drift without normalising for how long the drift
took. That is a bug in our hook, not a windfall, and it is written up in `FEEDBACK.md` §16.
