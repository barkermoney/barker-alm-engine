# Dashboard — both legs on one screen

MIT licensed. See the repository root [`LICENSE`](../LICENSE).

```bash
npm install
npm run dev        # http://localhost:5173
npm run build      # static site in dist/, deployable anywhere
npm run snapshot   # refresh the seed snapshot from Arc testnet (runs the keeper's indexer)
```

No wallet, no keys, no backend. Everything on the page is either read from chain by the browser
or recorded from a mainnet fork by a test in this repository.

## What is live and what is recorded

| Panel | Source | Live? |
|---|---|---|
| Arc positions, pool tick, base fee, per-swap fee log | Arc testnet RPC, from the browser, every 5 s | **live** |
| Who closed each position, keeper or owner | the close transaction's sender, checked against the registry's `KeeperSet` events | **live** |
| steakUSDC APY, size, share price | Ethereum mainnet RPC, from the browser, every 60 s | **live** |
| "What the guard does to a quote" | `XYCSwap`'s own arithmetic on the reserves each guard version hands it | computed |
| "One recorded run, end to end" | [`public/aqua-fork-trace.json`](public/aqua-fork-trace.json), written by `test_recordDashboardTrace` on an Ethereum mainnet fork | **recorded**, with the block it was recorded at |

The Aqua leg has no live deployment to read: 1inch's canonical SwapVM on mainnet predates the
repository's ABI (see [`../FEEDBACK-1INCH.md`](../FEEDBACK-1INCH.md) §4), so the leg runs on a
fork, which the brief explicitly allows. The dashboard says so on the page rather than dressing a
recording up as a feed.

## How the Arc panel gets its numbers

It does not keep its own copy of the indexing logic. [`src/arc.ts`](src/arc.ts) imports
`indexRange` and `summarisePositions` from [`../keeper/src/indexer.ts`](../keeper/src/indexer.ts)
and `readSlot0` / `conversionProgress` from [`../keeper/src/poolState.ts`](../keeper/src/poolState.ts),
so the positions on screen are folded by exactly the functions the keeper acts on.

On load it seeds an in-memory event log from [`public/events-5042002.json`](public/events-5042002.json)
— the keeper's own snapshot, committed so the page renders before any RPC call returns — then
catches up from that snapshot's cursor to the chain head with the same paginated, self-halving
`getLogs` loop the keeper uses, and polls from there. A stale snapshot costs a longer first sync,
never a wrong number: events are de-duplicated on `(block, logIndex)` either way.

Two v4 details show up directly on screen:

- **The base fee is read from `slot0.lpFee` via `extsload`**; the fee each swap actually paid comes
  from the PoolManager's `Swap` event, whose `fee` field is the hook's override when one is set.
  Our hook's `FeeApplied` is joined in only for the breakdown — surge, and the tick move behind it.
  We originally reported the opposite to Uniswap and found our mistake building this panel; see
  [`../FEEDBACK.md`](../FEEDBACK.md) §8, retracted and corrected Sep 10.
- **"vs. range mid-price"** is the realised price over the range's geometric mean. On a pool
  charging 0.30% the clean formula `fee / (1 − fee)` predicts +0.3009%; position #1 measured
  +0.3008%. That premium is the whole economic case for a range over a limit order.

## Attribution

The Aqua panel displays results from code in [`../aqua/`](../aqua/), which is SwapVM-1.1 licensed.
Per that licence the page carries *Powered by SwapVM — © Degensoft Ltd 2025* in its footer. No
SwapVM code is included in this directory.
