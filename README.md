# Barker ALM Engine

**Yield-backed automated liquidity management, in two legs:**

1. **Arc leg** — an automated *single-sided concentrated liquidity* manager built on **Uniswap v4** (custom hook + dynamic fee + one-sided `modifyLiquidity`), targeting **Circle's Arc** chain where USDC is the gas token and the native asset.
2. **Aqua leg** — a *yield-backed market making* app on **1inch Aqua / SwapVM**: the maker's backing capital sits in an ERC-4626 vault earning yield while simultaneously quoting stablecoin pairs; on fill it atomically redeems exactly what is needed and re-deposits the remainder.

The unifying thesis: **idle backing capital should earn while it backs quotes**, and **a liquidity range is a better execution primitive than a limit order** when the pool pays fees. Both legs are the same engine pointed at two venues.

Built for **ETHOnline 2026** on the **Continuity Track** by [Barker](https://barker.money) (solo).

---

## Status

| | |
|---|---|
| Event | ETHOnline 2026 (Sep 4 – Sep 16, 2026) |
| Track | Continuity — hacking on an existing project |
| Team | solo |
| Arc leg | deployed to Arc testnet, full lifecycle verified on chain ([tx list](arc/DEPLOYMENTS.md)) |
| Aqua leg | not started (scheduled D5–D8) |

---

## Pre-hackathon work vs. hackathon work

The Continuity Track requires prior work to be documented rather than hidden. This repository draws that line explicitly:

- **`research/arc-probe/` is pre-hackathon.** It is a *feasibility probe* written before the event (Aug 31 – Sep 2, 2026) to answer "can this even be built on Arc?". It landed in this repository's **initial commit**, unchanged, so that every subsequent commit is visibly hackathon work. It is throwaway probe code — not a product, not a submission artifact. See [`research/arc-probe/README.md`](research/arc-probe/README.md) for what it proved and what it cost.
- **Everything else is written during the event.** `arc/`, `aqua/`, `app/` and `docs/` start empty at the initial commit and grow from Sep 4, 2026 onward. The git history is the evidence.

Prior *product* work at Barker (the yield index, the execution layer, the ALM position management used for 1inch Aqua campaigns) lives in private repositories and is **not** included here. What this repository contains is new code written for this event, plus the documented probe above.

---

## Uniswap v4 integration — where to look

*(pointers for judging; see [`FEEDBACK.md`](FEEDBACK.md) for the integration experience write-up)*

| What | Where |
|---|---|
| v4 hook (dynamic fee, `afterInitialize` → `updateDynamicLPFee`) | `arc/src/` — see directory README |
| PoolManager interaction (`unlock` / `unlockCallback` → `modifyLiquidity` / `swap`, `sync`/`settle`/`take`) | `arc/src/` |
| One-sided range minting (the take-profit primitive) | `arc/src/` |
| Pre-hackathon v4 probe (helper + hook skeleton + CREATE2 hook mining) | `research/arc-probe/src/V4SidedHelper.sol`, `research/arc-probe/src/DynamicFeeHookStub.sol`, `research/arc-probe/script/MineHook.s.sol` |

Uniswap v4 is not a bolt-on here — the one-sided concentrated liquidity position *is* the product primitive, and the hook is what makes the fee schedule adapt to volatility.

---

## Licensing (read before copying)

This repository is **dual-licensed by directory**. The split is deliberate and load-bearing:

- **`aqua/` is licensed under `SwapVM-1.1`** (Degensoft Ltd source-available copyleft). Anything in that directory that links into, plugs into, or shares an EVM address space with SwapVM/Aqua inherits that license and **cannot** be relicensed as MIT.
- **Everything else is MIT** (see [`LICENSE`](LICENSE)) — the Arc/Uniswap v4 leg, the app layer, the docs, and the orchestration code, which are independent works that merely *call* external contracts.

> **Powered by SwapVM — © Degensoft Ltd 2025**

Do not move files across that directory boundary without re-checking which license follows them.

---

## AI usage disclosure

This project was built with AI assistance (Claude Code). Which files, which prompts, and which parts were human-written are disclosed in [`AI-DISCLOSURE.md`](AI-DISCLOSURE.md), with the working specs kept under [`docs/specs/`](docs/specs/).

---

## Layout

```
arc/           Arc leg — Uniswap v4 hook + one-sided CL manager (MIT)
aqua/          Aqua leg — SwapVM extensions, ERC-4626 backed maker (SwapVM-1.1)
app/           Minimal multi-position dashboard (MIT)
docs/          Architecture, schedule, specs
research/      Pre-hackathon feasibility probe (documented, not a submission artifact)
FEEDBACK.md    Uniswap v4 integration experience — the good, the sharp edges
```

## Links

- Barker — https://barker.money
- Architecture — [`docs/architecture.md`](docs/architecture.md)
- Build schedule — [`docs/schedule.md`](docs/schedule.md)
- Environment & pinned addresses — [`docs/environment.md`](docs/environment.md)
