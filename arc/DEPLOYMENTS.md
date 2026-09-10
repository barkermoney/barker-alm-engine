# Deployments

## Arc Testnet (chain id `5042002`) — Sep 4, 2026

Explorer: https://testnet.arcscan.app

### Contracts

| Contract | Address | Deploy tx |
|---|---|---|
| `BarkerV4Positions` | [`0x8ba4bFeC9616f2569AAB75AeC7B7411AA7F2a4Bb`](https://testnet.arcscan.app/address/0x8ba4bFeC9616f2569AAB75AeC7B7411AA7F2a4Bb) | [`0xc0d085ec…`](https://testnet.arcscan.app/tx/0xc0d085ecb6949454ca42d9a372292f2e6a2c0040d259b5772037ae403553b380) |
| `BarkerDynamicFeeHook` | [`0x31f6be09B9f63a26dfC894f9bBA7074047f59080`](https://testnet.arcscan.app/address/0x31f6be09B9f63a26dfC894f9bBA7074047f59080) | [`0xdca90503…`](https://testnet.arcscan.app/tx/0xdca905039fe46cb20c20664a12bc6ce5aa1e1193c0587aa7b2911141cd15e9de) |

The hook was placed by CREATE2 (deployer `0x4e59b448…`, salt `0x5ab`) at an address whose low 14 bits
are `0x1080` = `AFTER_INITIALIZE | BEFORE_SWAP`. The salt was found by
[`script/MineHookSalt.s.sol`](script/MineHookSalt.s.sol), which predicted the address before deployment.

Constructor parameters, read back from chain: `baseFee` 3000 (0.30%), `maxFee` 50000 (5%),
`surgePerTick` 20, `decayBlocks` 300, `governance` and `poolManager` as configured.

Live Uniswap v4 `PoolManager`: `0x2756F3F7bFAf103F4c550f4d24CdCa82B093240A`.

### Pool

`poolId` `0x3169c2477f74cfacfc7db206cd19628d3a6eb1b4d541afee840fc12e0fc1da60` —
BPROBE (`0x18B16C43…66A5`, 18dp) / USDC (`0x36000000…0000`, 6dp), dynamic fee, tick spacing 60.

### The full take-profit lifecycle, on chain

Six transactions, in order. A range placed above spot, funded only in the base asset, sold into a
rising price and came back entirely in USDC.

| # | Step | Tx | Result |
|---|---|---|---|
| 1 | `initialize` | [`0x31c6685d…`](https://testnet.arcscan.app/tx/0x31c6685dfe60dc576c207e9fbfc578520543ab17494f3d8c1ccc9dc9b5274ee3) | Pool created at tick −368460. The hook's `afterInitialize` fired: `slot0.lpFee` reads back **3000**. |
| 2 | `approve` | [`0xa83da27f…`](https://testnet.arcscan.app/tx/0xa83da27fe69874cdb828afc841f43aab0ae9c9d93904f41e91f71629a9095ca6) | BPROBE allowance to the position manager. |
| 3 | **`open`** | [`0xf6f0bd20…`](https://testnet.arcscan.app/tx/0xf6f0bd20b6b5dd00c55bea6bec94fa0e5cdad0f68dca27402bc61ef12dbb697b) | Position #1, range [−368100, −367500] = **+3.67% … +10.08%** above spot. Debited **19,999.999999999964117400 BPROBE and zero USDC** — a single ERC-20 `Transfer` log in the whole receipt. |
| 4 | `approve` | [`0x821db063…`](https://testnet.arcscan.app/tx/0x821db063f0485bd05a64d20e8a21d105948f9fb226388f5e6daef6ecb8899496) | USDC allowance for the swap leg. |
| 5 | **`swap`** | [`0x1fb79d53…`](https://testnet.arcscan.app/tx/0x1fb79d530e4e605366cddf313a904467995ffe08f6a65a5ebc8770e93ee4ea0e) | 2.136892 USDC in, price driven **through** the range and stopped precisely at the limit tick −367380. The hook emitted `FeeApplied(fee=3000, surge=0, move=0)` — correct: first swap after initialize, nothing had moved yet. |
| 6 | **`close`** | [`0xa00b33c5…`](https://testnet.arcscan.app/tx/0xa00b33c540be185c34cc1a8d12147f9d7255a7ff702cac8b4ae234fdedf5243d) | Returned **0 BPROBE and 2.136890 USDC**. Fully converted. |

### What the numbers say

| | |
|---|---|
| Principal in | 19,999.999999999964117400 BPROBE |
| Returned | 2.136890 USDC, zero base asset |
| Realised price | 1.068445e−16 (raw, token1/token0) |
| Range geometric mean | 1.065240e−16 |
| **Premium over geometric mean** | **+0.3008%** |
| Theoretical `fee / (1 − fee)` at 0.30% | +0.3009% |
| Realised gain vs. spot at open | **+7.14%**, inside a +3.67% … +10.08% range |

The premium is the point. A ladder sells across its span at the geometric mean, which is *worse*
than a limit order resting at the top of the range — so the fee is the entire reason to use a range
instead. Measured here at **+0.3008%**, against a clean-formula prediction of **+0.3009%** — agreement
to within one part in a million, with no fudge factor.

> **Corrected Sep 8.** An earlier version of this table read 2.137914 USDC and a +0.3489% premium,
> and explained the 0.048% gap as v4 per-step rounding falling to the LP. That explanation was
> invented to cover a transcription error: both the swap and the close figures had been recorded
> 1,024 raw units (0x400) high. The authoritative values are the `Swap` and `PositionClosed` event
> payloads, now read back by [`keeper/`](../keeper/) rather than by hand — `0x209b3a` = 2,136,890.
> The corrected number needs no rounding story at all, which is how we know it is the right one.

The realised +7.14% also lands where it should: above the range's lower bound, below its upper, near
the geometric middle. This is the same behaviour the pre-hackathon probe measured (+8.46% on a
+5.25% … +11.76% range), now reproduced through the actual position manager rather than a bare
helper.

### Cost

**0.081341 USDC total** for all six transactions plus both deployments — gas on Arc is paid in USDC.

Note for anyone reading the balances: one wallet played both liquidity provider and swapper here, so
the net token movement round-trips. The position's own accounting is the meaningful part, and it is
in the `PositionOpened` / `PositionClosed` events.

---

## Sep 8, 2026 — the keeper closes a position unattended

Same contracts, same pool. What is new is that **no human sent the closing transaction**: the
off-chain keeper ([`../keeper/`](../keeper/)) watched the pool, decided the ladder had finished
converting, and closed it on its own key.

### The keeper

| | |
|---|---|
| Keeper address | [`0xA980cCF5224baA2E2AeC59C6022a57433645D33d`](https://testnet.arcscan.app/address/0xA980cCF5224baA2E2AeC59C6022a57433645D33d) |
| Position owner | `0x7ad19e19430875d53c2E745ec781fBF613506C8E` |
| Authorised by | [`0x31962012…`](https://testnet.arcscan.app/tx/0x31962012fddb1acf2ad3fa878ced5d623066e32bcd5a232f45cd051339fbf09b) — `setKeeper(0xA980…, true)` |
| Funded with | [`0x05c8d368…`](https://testnet.arcscan.app/tx/0x05c8d368128270a8c7d269c7c85eebac5b01f726b5f5d9b7a2d2e8dfb253a7b7) — 1.0 USDC of gas |

A freshly generated key, not the owner's. The point of the exercise is that `close` pays the
position's owner and takes no recipient argument, and that claim is only testable when the two
addresses actually differ.

### Position #2

| # | Step | Tx | Result |
|---|---|---|---|
| 1 | `open` | [`0xbe0680fd…`](https://testnet.arcscan.app/tx/0xbe0680fd767a2f88e9a9a35358959f66565694e61f22127b40c9bd5a4d7c6ab2) | Range `[−367320, −367140)` = **+0.60% … +2.43%** above a spot of −367380. Debited 19,999.999999999922458964 BPROBE, zero USDC. |
| 2 | `swap` | [`0x59d12358…`](https://testnet.arcscan.app/tx/0x59d12358cf619de41eb99659eb17f6a37bf382824d026217e3c164aa9d1e035c) | 2.312324 USDC in from a separate wallet, price driven to the limit tick −367080. |
| 3 | **`close`, sent by the keeper** | [`0xbc03cc81…`](https://testnet.arcscan.app/tx/0xbc03cc81944930febc3811292958cf1bc078c08bc3b14f5a58a0083a931c269b) | **0 BPROBE and 2.312322 USDC, paid to the owner.** 128,711 gas. |

Between steps 2 and 3 the keeper logged two `ARM` passes and then acted on the third, ~21 seconds
after the price moved. Nothing prompted it. The full log is in
[`../keeper/README.md`](../keeper/README.md).

**The custody check.** The keeper began with 1.0 USDC and ended with 0.997406 — it spent 0.002594
on gas and received nothing. Its BPROBE balance is zero. The `Transfer` in the close receipt goes
from the PoolManager straight to `0x7ad19e19…`, the owner.

### 🔴 What this run exposed: the hook billed 2.46%, not 0.30%

The position came back **+4.07% against spot** on a range that tops out at +2.43% — arithmetically
impossible for a ladder on its own. The `FeeApplied` event explains it:

```
FeeApplied(fee = 24600, surge = 21600, tickMove = 1080)
```

The dynamic fee hook charged **2.46%**. The hook's surge term is `|ticks moved since the previous
swap| × surgePerTick` — 1,080 × 20 = 21,600 — and those 1,080 ticks are **the Sep 4 swap's own price
impact** (step 5 above: −368,460 → −367,380), billed to the next trader 588,318 blocks later. Nothing
moved in between; a v4 pool's price only moves through its own swaps, and every one of them passes
the hook. The hook dated the move to the block it *observed* it rather than the block it *happened*,
so stored surge decayed and the move never did.

*Corrected Sep 10.* The Sep 8 version of this paragraph called the 1,080 ticks "drift" over four days
and the defect a missing normalisation for elapsed time. The event log shows two swaps and no drift;
see [`../FEEDBACK.md`](../FEEDBACK.md) §16 for the retraction.

So the +4.07% is not evidence the ladder works better than the math says. It is fee revenue the
position charged because of a defect in our own hook, and on a real pool a 2.46% quote would simply
have driven the trade elsewhere. On this branch the incident is replayed on the deployed parameters
by `test_moveFromLongAgo_isNotCharged_sep8Replay` in
[`test/BarkerDynamicFeeHook.t.sol`](test/BarkerDynamicFeeHook.t.sol); it is written up in
[`../FEEDBACK.md`](../FEEDBACK.md) §16, and **not fixed in the deployed hook** — a hook's permission
bits live in its address, so a corrected hook is a new address, a new `PoolKey`, and a new pool. The
fix itself (date the move to `lastBlock` and decay it with the stored surge) is on branch
[`fix/fee-hook-clock`](https://github.com/barkermoney/barker-alm-engine/tree/fix/fee-hook-clock),
tested and undeployed; whether to redeploy before submission is decision 0 in
[`../docs/schedule.md`](../docs/schedule.md).

### Also corrected today

`feesOwed` on the position registry returned `getFeeGrowthInside` — a Q128 accumulator — where
callers would read token amounts, an error of about 2^128 in a view that had no test. It now
computes `liquidity × (growthInside − growthInsideLast) / 2^128` and is asserted against what
`collect` actually pays. See `../FEEDBACK.md` §15.

### Cost

**0.015448 USDC** for the six transactions of this run, on top of the 0.081341 spent on Sep 4 —
0.012854 paid by the owner across five transactions, 0.002594 paid by the keeper for the close.
