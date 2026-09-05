# Environment

Everything below was verified live on **Sep 4, 2026**. Addresses are pinned rather than discovered at runtime, because two of the three prize submissions depend on a judge being able to reproduce what we claim.

## Arc testnet (the Arc leg)

| | |
|---|---|
| Chain ID | `5042002` |
| RPC | `https://rpc.testnet.arc.io` |
| Explorer | `https://testnet.arcscan.app` |
| Faucet | `https://faucet.circle.com` — 20 USDC / 2h / address, CAPTCHA-gated |
| Gas token | **USDC**, 18 decimals natively |
| Gas price observed | 25 gwei (minimum 20) |
| Verified at | block 60,510,408 |

### Pinned contracts

| What | Address |
|---|---|
| Uniswap v4 `PoolManager` (live, verified, standard v4 interface) | `0x2756F3F7bFAf103F4c550f4d24CdCa82B093240A` |
| USDC ERC-20 shell | `0x3600000000000000000000000000000000000000` |
| Native ledger (mirrors USDC transfers as 18-decimal events) | `0xffff…fffe` |
| CREATE2 deployer (for hook address mining) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |

The canonical v4 address `0x…4444` is **empty** on Arc testnet. The PoolManager above is a third-party deployment and is the one with actual activity; it tracks `v4-core` HEAD rather than a tag, so clone `v4-core` at HEAD to keep ABIs aligned.

Probe-era contracts from the pre-hackathon work are still live and can be used as reference deployments: helper `0x1B854Ab2cf1CD3e92079E9aaE1f6A20f0FDc8729`, dynamic-fee hook `0xa1021F8D8e2a38a9bDD455e50feb4aCf54f5b000`.

### 🔴 The USDC rule

Arc's USDC is a **native precompile** behind an ERC-20 shell. Foundry's local fork does not implement it, so any USDC-touching call reverts with `StackUnderflow` under `forge script` / `forge test` — and because `forge script` simulates before broadcasting, a USDC-touching script **silently never broadcasts while printing success**.

**Rule: anything touching USDC executes through `cast` against a real node. Never through `forge script` simulation. Tests mock the precompile.**

This is not a preference. It is the difference between a transaction that happened and a transaction that only appeared to.

## Ethereum mainnet fork (the Aqua leg)

| | |
|---|---|
| RPC | `https://ethereum-rpc.publicnode.com` |
| Verified at | block 25,908,224 |
| Fork tool | `anvil --fork-url $ETH_RPC_URL --fork-block-number <pinned>` |

Pin the fork block once the Aqua leg starts (D6) so test results are reproducible for judges.

Official Aqua / SwapVM contract addresses are pinned at D6 from the official 1inch repositories. The 1inch bounty **requires** official contracts, though redeploying a *modified* SwapVM is explicitly permitted — which is the path for the custom-opcode variant.

### ERC-4626 backing vault

**Primary target: `steakUSDC`** — `0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB`

| | |
|---|---|
| Underlying | USDC (`0xA0b8…eB48`) |
| Total assets | ~$69.3M (verified on-chain) |
| Curator | Steakhouse Financial, on MetaMorpho |

Chosen for three reasons: it is USDC-denominated, which matches both the Aqua stablecoin pairs and the Arc leg's USDC theme; it is large enough that its APY is a real number rather than an artifact; and it is a vault with a real curator rather than a toy, which matters for the claim that backing capital "earns while it backs quotes."

Fallbacks if a second vault is needed for tests: `gtUSDCcore` `0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458` (~$5.5M, USDC) and `sDAI` `0x83F20F44975D03b1b09e64809B757c47f942BEeA` (DAI).

## Keys

Deployer addresses are supplied through environment variables (`ARC_DEPLOYER`, etc.) and are not committed. No private key ever enters this repository, and no automated process holds one — every transaction that moves funds is signed by a human.
