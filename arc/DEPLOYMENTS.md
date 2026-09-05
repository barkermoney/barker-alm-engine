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
| 3 | **`open`** | [`0xf6f0bd20…`](https://testnet.arcscan.app/tx/0xf6f0bd20b6b5dd00c55bea6bec94fa0e5cdad0f68dca27402bc61ef12dbb697b) | Position #1, range [−368100, −367500] = **+3.67% … +10.08%** above spot. Debited **19,999.999999999999964 BPROBE and zero USDC** — a single ERC-20 `Transfer` log in the whole receipt. |
| 4 | `approve` | [`0x821db063…`](https://testnet.arcscan.app/tx/0x821db063f0485bd05a64d20e8a21d105948f9fb226388f5e6daef6ecb8899496) | USDC allowance for the swap leg. |
| 5 | **`swap`** | [`0x1fb79d53…`](https://testnet.arcscan.app/tx/0x1fb79d530e4e605366cddf313a904467995ffe08f6a65a5ebc8770e93ee4ea0e) | 2.137916 USDC in, price driven **through** the range and stopped precisely at the limit tick −367380. The hook emitted `FeeApplied(fee=3000, surge=0, move=0)` — correct: first swap after initialize, nothing had moved yet. |
| 6 | **`close`** | [`0xa00b33c5…`](https://testnet.arcscan.app/tx/0xa00b33c540be185c34cc1a8d12147f9d7255a7ff702cac8b4ae234fdedf5243d) | Returned **0 BPROBE and 2.137914 USDC**. Fully converted. |

### What the numbers say

| | |
|---|---|
| Principal in | 19,999.999999999999964 BPROBE |
| Returned | 2.137914 USDC, zero base asset |
| Realised price | 1.068957e−16 (raw, token1/token0) |
| Range geometric mean | 1.065240e−16 |
| **Premium over geometric mean** | **+0.3489%** |
| Theoretical `fee / (1 − fee)` at 0.30% | +0.3009% |
| Realised gain vs. spot at open | **+7.20%**, inside a +3.67% … +10.08% range |

The premium is the point. A ladder sells across its span at the geometric mean, which is *worse*
than a limit order resting at the top of the range — so the fee is the entire reason to use a range
instead. Measured here at **+0.3489%**, against a clean-formula prediction of +0.3009%. The extra
~0.048% is v4's per-step rounding, which resolves in the pool's — that is, the liquidity provider's —
favour.

The realised +7.20% also lands where it should: above the range's lower bound, below its upper, near
the geometric middle. This is the same behaviour the pre-hackathon probe measured (+8.46% on a
+5.25% … +11.76% range), now reproduced through the actual position manager rather than a bare
helper.

### Cost

**0.081341 USDC total** for all six transactions plus both deployments — gas on Arc is paid in USDC.

Note for anyone reading the balances: one wallet played both liquidity provider and swapper here, so
the net token movement round-trips. The position's own accounting is the meaningful part, and it is
in the `PositionOpened` / `PositionClosed` events.
