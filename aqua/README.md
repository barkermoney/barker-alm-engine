# Aqua leg — a yield-backed maker on SwapVM

> **Powered by SwapVM — © Degensoft Ltd 2025**

**Not MIT licensed.** This directory is SwapVM-1.1; see [`NOTICE.md`](NOTICE.md) and [`LICENSES/`](LICENSES/). The repository root `LICENSE` does not reach here.

## The idea

Market-making capital normally sits idle waiting to be hit. A **yield-backed maker** keeps it in an ERC-4626 vault instead — [steakUSDC](https://etherscan.io/address/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB), Steakhouse Financial's MetaMorpho vault, in our case — and redeems only what a fill actually needs. The maker's return becomes *vault APY + spread* rather than spread alone.

That only works if the quoting side knows the difference between the reserves a strategy advertises and the capital it can actually produce. Otherwise the maker quotes fills it cannot settle, and the taker pays gas to find out.

## Contracts

| Contract | What it does |
|---|---|
| [`src/YieldBackedSolvencyGuard.sol`](src/YieldBackedSolvencyGuard.sol) | An `Extruction` target that caps quotable depth at `min(virtual reserve, liquid + redeemable, allowance)` — evaluated at quote time, against the live vault position. |
| [`src/YieldBackedSettlement.sol`](src/YieldBackedSettlement.sol) | An `IMakerHooks` target that settles fills against the vault: `preTransferOut` redeems the payout just in time, `postTransferIn` deposits the taker's payment before the transaction ends, and a per-order **buffer ratio** decides how much stays liquid between fills. |

Together they close the loop: the guard makes the *quote* honest, settlement makes the *fill* work — `test_quoteAndSettlementAgree` pins the joint invariant that the quoted amount and the settled amount are the same number, on mocks and on a mainnet fork against live steakUSDC.

## How the guard works

The cap lands on `balanceOut` — the reserve the pricing curve runs on — **before** the curve is evaluated, not on the amount that comes out of it, and `balanceIn` is scaled down by the same factor. Curves price off the reserve *ratio*, so keeping the ratio keeps the price: a small fill quotes the same rate with or without the guard, depth shrinks, price walks up the same shape sooner, and every quote the strategy can emit is one the maker can settle.

> **Corrected Sep 10.** The first version capped `balanceOut` alone. That kept every quote settleable but moved the price: on the mainnet fork a maker backing 500k USDC behind 10M virtual reserves quoted **12,195 USDC for 250,000 USDT** — USDC at a twentieth of its value — the instant the guard engaged. All 40 tests passed, because each one checked the cap and none checked the price; the headline assertion compared the guarded quote against the same broken formula. Now pinned from three sides: a unit test on the scaled registers, a fuzz test that the reserve ratio moves by at most one unit of rounding and only in the maker's favour, and `test_guardKeepsThePriceAndTrimsOnlyTheDepth` through the real router. The same fork scenario now quotes **166,667 USDC** for 250,000 USDT — a 500k-deep book taking a half-book fill.

Placement in the strategy program is load-bearing:

```
StaticBalances(reserveA, reserveB)     ← reserves set
Extruction(guard, [vault address])     ← cap applied here
XYCSwap()                              ← curve reads the capped reserve
Salt(...)
```

Three properties worth calling out, each pinned by a test:

- **Ceiling, never floor.** A modest reserve is left alone; the guard can only reduce. Raising it would be a way to quote depth the strategy never authorised.
- **Reads `maxWithdraw`, not `convertToAssets`.** A vault that cannot currently service a redemption is not backing anything, whatever the share price says. MetaMorpho vaults deploy into Morpho markets and throttle exactly this way when markets are fully utilised.
- **Quote and swap cannot diverge.** `IExtruction` and `IStaticExtruction` share one selector, so implementing only the `view` form puts both paths on the same bytecode. This is structural, not a convention — see [`../FEEDBACK-1INCH.md`](../FEEDBACK-1INCH.md) §2.

## How settlement works

SwapVM pays the taker with a plain `transferFrom(maker, taker)`, so at transfer time the quoted
amount has to exist as loose tokens in the maker's wallet — which is exactly what a yield-backed
maker does not keep. Two hooks bridge the gap, both running inside the swap transaction:

- **`preTransferOut` — redeem-on-fill.** If the wallet holds less than the fill needs, the
  difference is withdrawn from the vault, plus enough on top to restore the liquid buffer. One
  redemption serves this fill and the next few.
- **`postTransferIn` — redeposit-on-receive.** Anything above the buffer target goes straight back
  into that side's vault: inbound inventory starts earning in the same transaction that delivered it.

The **buffer ratio** (basis points of the total position, per order side) is the knob between gas
and yield: at 0 every fill touches the vault and every incoming dollar is deposited immediately;
a wider buffer absorbs small fills entirely at the cost of keeping that slice idle.

The settlement contract holds no funds and has no owner. It acts only on maker allowances, and
every token it moves goes between the maker and a vault position owned by the maker. A maker
enables it with three approvals: payout token → router (the swap itself), vault shares → settlement
(redeem-on-fill), inbound token → settlement (redeposit). Revoking any of them switches that leg off.

## Why the signature track, not the Aqua custodial track

SwapVM authorises a maker one of two ways, and the choice also decides *where the capital lives*:

| | Capital sits in | Reserves come from |
|---|---|---|
| Aqua custodial track | the Aqua ledger | the ledger's accounting |
| Signature track | the maker's own address | `StaticBalances` / `DynamicBalances` |

Capital in the Aqua ledger has stopped earning, so a yield-backed maker cannot use the custodial track at all — the `AquaOpcodes` set has no `StaticBalances`, which is the same fact showing up as an opcode. Our maker therefore holds its position in the vault and lets `SwapVMRouter` pull against an allowance. `FEEDBACK-1INCH.md` §5 covers this, and sketches the ledger change that would lift the restriction.

## Build and test

```bash
git clone https://github.com/1inch/swap-vm.git lib/swap-vm
cd lib/swap-vm && yarn install && cd ../..
forge test
```

`lib/` is git-ignored, so upstream is fetched rather than vendored. Remappings in `foundry.toml` point at `lib/swap-vm/node_modules`, which is where SwapVM keeps its own dependencies — including `@1inch/aqua`, which is a separate package rather than part of the repository.

The compiler profile (solc 0.8.30, `via_ir`, `optimizer_runs = 700`) matches upstream deliberately. Diverging surfaces as stack-too-deep inside the vendored sources rather than in our own.

### The suites

| Suite | What it proves | Needs RPC |
|---|---|---|
| `test/YieldBackedSolvencyGuard.t.sol` | Cap semantics at the boundaries: vault, buffer, allowance, exact-output, malformed args, quote/swap identity | no |
| `test/SolvencyGuardOnSwapVM.t.sol` | The same behaviour reached through an unmodified `SwapVMRouter` and the official `Extruction` opcode | no |
| `test/SolvencyGuardMainnetFork.t.sol` | Live steakUSDC and real USDC on an Ethereum mainnet fork | `ETHEREUM_RPC_URL` |

The fork suite skips rather than fails when `ETHEREUM_RPC_URL` is unset, so an offline run stays green and honest about what it did not check.

```bash
ETHEREUM_RPC_URL=https://eth.drpc.org forge test
```

Any mainnet RPC works if it serves state at a block a few seconds old. As of Sep 10 publicnode no longer does without a personal token — it answers `Archive requests require a personal token` and the fork suites fail in `setUp`. `eth.drpc.org`, `rpc.flashbots.net` and `eth-mainnet.public.blastapi.io` were verified on that date.

**On the fork suite and the canonical address:** SwapVM's README points integrators at `0x111111338c5091E8440b67B168bAe16a668AC0De`. That deployment is live on mainnet but predates the current repository — the `quote` selector generated from HEAD is absent from its bytecode. The suite therefore deploys the router from unmodified upstream source and keeps everything else on the fork real. `test_canonicalDeploymentHasDriftedFromHead` pins the drift down so a future redeploy turns it green.
