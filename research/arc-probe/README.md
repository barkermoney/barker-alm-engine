# Arc feasibility probe — pre-hackathon work

> **This directory is pre-hackathon work and is not a submission artifact.**
>
> It was written **Aug 31 – Sep 2, 2026**, before ETHOnline 2026 began (Sep 4, 09:00 PT), to answer a single question: *is the Arc chain a viable venue for a Uniswap v4 one-sided concentrated liquidity manager?* It is deliberately committed here **unchanged, in this repository's initial commit**, so the boundary between prior work and hackathon work is visible in the git history rather than asserted in prose.
>
> It is throwaway probe code: owner-only, single-signer, no access control worth the name, no tests. Do not read it as product code. The product code is in [`../../arc/`](../../arc/) and starts from the next commit.

## What it was probing

Arc is Circle's L1, going to public mainnet on Sep 16, 2026, with **USDC as the gas token**. That combination is unusual enough that "will a v4 ALM even work here?" was a genuine open question, not a formality.

## What it proved

**Everything needed. The probe came back green on all counts.**

| # | Question | Answer |
|---|---|---|
| 1 | Permissionless deployment on Arc testnet? | Yes |
| 2 | Is there a live Uniswap v4 PoolManager? | Yes — a third-party deployment, standard v4 interface, verified. The canonical `0x…4444` address is empty; the live one is not. |
| 3 | Does the full one-sided lifecycle work on-chain? | Yes — init pool → mint one-sided → swap through the range → burn. Seven real transactions. |
| 4 | Custom hook with dynamic fees? | Yes — CREATE2-mined hook (flags `0x3000`), `afterInitialize` → `updateDynamicLPFee(1%)`, read back from `slot0` as `lpFee = 10000`. |
| 5 | Is USDC-as-gas workable from Foundry? | Yes — EIP-1559, minimum 20 gwei. A full "deploy token + create 1% pool + initialize" transaction cost ~4.94M gas ≈ **$0.10**. |
| 6 | EVM feature parity? | Cancun / EIP-1153 transient storage available. No `PREVRANDAO`, no blobs — neither matters for us. |

### The take-profit primitive, measured

The whole product rests on one claim: *a one-sided range above spot is an automated take-profit ladder.* The probe measured it end to end on Arc testnet — minted 20,000 probe tokens across a `+5.25% … +11.76%` range (on-chain: only the base token was debited, zero USDC), swapped through it, and burned. Realized average sale price: **+8.46%**, the geometric mean of the range. Textbook, no bespoke machinery required.

## The one sharp edge worth carrying forward

🔴 **Arc's USDC is a native precompile, and Foundry's local fork does not know about it.**

The ERC-20 at `0x3600…` is a shell that `delegatecall`s to `0xC6AD…`, which reaches a precompile at `0x1800…` (6-decimal shell over an 18-decimal native ledger). Foundry's local simulation does not implement it, so **any operation touching USDC reverts with `StackUnderflow` inside `forge script` / `forge test`.**

The dangerous part is not the revert — it is that `forge script`'s all-or-nothing simulate-then-broadcast means a USDC-touching script **never broadcasts** while still printing what looks like a successful mint. It reports success for a transaction that never happened.

**Rule adopted for all Arc work:** anything touching USDC goes through `cast` against a real node, never through `forge script` simulation. Foundry tests must mock the precompile.

There is a second, benign consequence: Arc's native ledger at `0xffff…fffe` mirrors every USDC transfer as **two** events (18-decimal native + 6-decimal shell). Indexers need to pick one and not double-count. We use it deliberately.

## Contents

| File | What it is |
|---|---|
| `src/V4SidedHelper.sol` | ~90-line v4 helper: `unlock` / `unlockCallback` routing to `modifyLiquidity` and `swap`, with `sync`/`settle`/`take` accounting. No `v4-periphery` dependency; liquidity computed off-chain. |
| `src/DynamicFeeHookStub.sol` | Minimal hook skeleton — sets the dynamic LP fee in `afterInitialize`. |
| `src/LaunchProbe.sol` | Earlier v3-era probe: deploy a token, create a 1% pool, and initialize it in one transaction. Kept as the gas/cost datapoint. |
| `script/MineHook.s.sol` | CREATE2 salt miner for hook permission flags. |
| `script/SingleSidedLP.s.sol`, `script/SwapOnly.s.sol`, `script/EncodeV4Mint.s.sol` | Lifecycle scripts. Note the calldata-encoding split — a consequence of the USDC precompile rule above. |
| `calc_params.py` | High-precision tick/liquidity math for the probe (`sqrtPriceX96`, one-sided `L`, range-crossing cost, swap price limit). |

## What is deliberately **not** here

- **Build outputs and dependencies** (`out/`, `cache/`, `lib/`) — reproduce with `forge install`.
- **The backtester and strategy parameters.** The probe phase included a historical backtest over ~155k swaps used to validate the strategy's profitability. That is Barker's proprietary strategy research and stays private. What is open here is the **execution layer** — how a position is opened, managed, and closed — not which parameters to open it with.
- **Barker production contracts.** Draft copies of an internal position router sat in the probe working directory and were excluded.

## Reproducing

```bash
forge install
forge build
```

Arc testnet: chain id `5042002`, RPC `rpc.testnet.arc.io`, explorer `testnet.arcscan.app`, faucet `faucet.circle.com` (20 USDC / 2h / address, CAPTCHA-gated).
