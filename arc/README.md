# Arc leg — one-sided concentrated liquidity on Uniswap v4

MIT licensed. See the repository root `LICENSE`.

## Contracts

| Contract | What it does |
|---|---|
| [`src/BarkerV4Positions.sol`](src/BarkerV4Positions.sol) | Opens, holds and closes **one-sided** v4 positions. Enforces one-sidedness against the live tick and then re-checks it against the pool's own accounting. Custody stays with the position owner: keepers can close, but never redirect proceeds. |
| [`src/BarkerDynamicFeeHook.sol`](src/BarkerDynamicFeeHook.sol) | v4 hook. Surge fee — the LP fee rises with realized volatility measured between swaps and decays linearly back to a base rate. Permissions `AFTER_INITIALIZE \| BEFORE_SWAP` (address flags `0x1080`). |

## Uniswap v4 integration points

For reviewers looking for the v4 surface specifically:

- **PoolManager lock pattern** — `BarkerV4Positions.unlockCallback`, reached via `poolManager.unlock` from `open` / `close` / `collect`.
- **`modifyLiquidity`** — `BarkerV4Positions.unlockCallback`; a zero `liquidityDelta` is the fee-collection path.
- **Flash accounting** (`sync` / `settle` / `take`) — `BarkerV4Positions._settle`.
- **Position salt** — `BarkerV4Positions.saltFor`, derived from the registry id so positions sharing a range stay distinct in PoolManager accounting.
- **Hook permission flags checked against the hook's own address** — `BarkerDynamicFeeHook` constructor.
- **`afterInitialize` → `updateDynamicLPFee`** — `BarkerDynamicFeeHook.afterInitialize`.
- **`beforeSwap` returning an LP fee override** — `BarkerDynamicFeeHook.beforeSwap`, using `LPFeeLibrary.OVERRIDE_FEE_FLAG`.

## Build and test

```bash
forge install
forge build
forge test
```

`v4-core` is pinned at HEAD rather than a tag: deployed PoolManagers on Arc track HEAD, and a tag produces ABI mismatches that only surface as runtime decode failures. See `FEEDBACK.md` at the repository root.

Tests deploy a real `PoolManager` and mock ERC-20s. They deliberately do **not** touch Arc's USDC, which is a native precompile that Foundry does not implement — those paths are exercised on-chain with `cast`. See `docs/environment.md`.

## Deploying to Arc

The split is load-bearing, not stylistic: **Foundry computes, `cast` transacts.**

Arc's USDC is a native precompile that Foundry's EVM does not implement, so a `forge script`
touching USDC simulates a revert, broadcasts nothing, and prints something that looks like success.
Everything that moves USDC therefore goes through `cast` against a real node.

| Step | Tool | Why |
|---|---|---|
| `script/MineHookSalt.s.sol` | `forge script` | Pure computation — finds a CREATE2 salt placing the hook at an address carrying flags `0x1080`. |
| `script/DeployArc.s.sol` | `forge script --broadcast` | Contract deployment only. Moves no USDC, so simulation is safe. |
| `script/Params.s.sol` | `forge script` | Tick and liquidity math. Prints integers for the next step. |
| `script/lifecycle.sh` | `cast send` | Everything that moves tokens: approve, initialize, open, swap, close. |

```bash
# 1. find the hook's salt
POOL_MANAGER=0x2756F3F7bFAf103F4c550f4d24CdCa82B093240A GOVERNANCE=<gov> \
  forge script script/MineHookSalt.s.sol:MineHookSalt

# 2. deploy
POOL_MANAGER=... GOVERNANCE=... HOOK_SALT=... \
  forge script script/DeployArc.s.sol:DeployArc --rpc-url arc_testnet --broadcast

# 3. run the lifecycle
export ARC_PRIVATE_KEY=0x... POSITIONS=0x... HOOK=0x...
./script/lifecycle.sh preflight
./script/lifecycle.sh init-pool
./script/lifecycle.sh approve && ./script/lifecycle.sh open
./script/lifecycle.sh approve-swap && ./script/lifecycle.sh swap
./script/lifecycle.sh close
```
