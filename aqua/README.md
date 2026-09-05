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

Settlement (`IMakerHooks`: redeem-on-fill, redeposit-on-receive) lands next; see [`../docs/schedule.md`](../docs/schedule.md).

## How the guard works

The cap lands on `balanceOut` — the reserve the pricing curve runs on — **before** the curve is evaluated, not on the amount that comes out of it. So the quote stays *on* the curve: depth shrinks, price walks up the same shape, and every quote the strategy can emit is one the maker can settle.

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
ETHEREUM_RPC_URL=https://ethereum-rpc.publicnode.com forge test
```

**On the fork suite and the canonical address:** SwapVM's README points integrators at `0x111111338c5091E8440b67B168bAe16a668AC0De`. That deployment is live on mainnet but predates the current repository — the `quote` selector generated from HEAD is absent from its bytecode. The suite therefore deploys the router from unmodified upstream source and keeps everything else on the fork real. `test_canonicalDeploymentHasDriftedFromHead` pins the drift down so a future redeploy turns it green.
