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
