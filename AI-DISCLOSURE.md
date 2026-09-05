# AI usage disclosure

ETHOnline 2026 requires entrants to document *where and how* AI tools were used, down to specific
files. This is that disclosure, kept current as the build proceeds.

## Tooling

**Claude Code** (Anthropic) was the primary assistant, used interactively from a terminal. No other
code-generating AI tool was used.

**No spec-driven framework was used** — no OpenSpec, Kiro, or spec-kit. Direction was given
conversationally, plus the design documents that are themselves committed here:
[`docs/architecture.md`](docs/architecture.md) and [`docs/schedule.md`](docs/schedule.md) were
written before the code they describe and are the closest thing to a written spec this project has.
There is no separate hidden prompt corpus; if there were, the rules would require it here and it
would be here.

## Per-file attribution

| Path | AI involvement |
|---|---|
| `arc/src/BarkerV4Positions.sol` | **Substantially AI-drafted** from a stated design. The design decisions — enforcing one-sidedness against the live tick *and* re-checking against the pool's accounting, keeping custody with the position owner so a keeper can never redirect proceeds, pausing that blocks opening but never closing — are the author's, given as instructions. Read line by line and revised before commit. |
| `arc/src/BarkerDynamicFeeHook.sol` | **Substantially AI-drafted.** The mechanism (sample tick in `beforeSwap`, charge for movement since the last swap, decay linearly) and the constructor self-address check were specified by the author; the implementation is AI. |
| `arc/test/*.sol` | **Substantially AI-drafted.** Cases were specified by the author; the assertions on the fee premium came out of a test failing and the number being investigated. |
| `arc/script/*.s.sol`, `arc/script/lifecycle.sh` | **Substantially AI-drafted.** The forge-computes / cast-transacts split is a constraint of the chain (see `docs/environment.md`), decided by the author. |
| `aqua/src/YieldBackedSolvencyGuard.sol` | **Substantially AI-drafted.** The author specified the cap formula `min(virtual, liquid + redeemable, allowance)`, that it must land on the reserve rather than on the resulting amount so the quote stays on the curve, and that the guard may only ever reduce. Reading `maxWithdraw` rather than `convertToAssets`, and implementing only the `view` interface so quote and swap share one selector, were AI proposals the author accepted after review. |
| `aqua/test/*.sol`, `aqua/test/mocks/*.sol` | **Substantially AI-drafted.** The mainnet-fork findings — the canonical deployment's ABI drift, `AquaOpcodes` lacking `StaticBalances` — came out of tests failing against the real chain and being investigated, not from generated commentary. |
| `README.md`, `FEEDBACK.md`, `FEEDBACK-1INCH.md`, `aqua/README.md`, `docs/*`, this file | **AI-drafted prose, author's content.** Every finding in both feedback files is something actually hit during this build. |
| `research/arc-probe/**` | Pre-hackathon probe, AI-assisted at the time it was written (Aug 31 – Sep 2). Committed unmodified; see its README. |
| Strategy design, venue selection, licensing analysis, product decisions | **Human.** Decided before and outside the AI loop. |
| Key handling, transaction signing, deployment decisions | **Human.** See below. |

## What AI did not do

- It did not choose the strategy, the venues, or the product.
- It did not hold keys or decide to broadcast. Every transaction that moves funds is authorised by
  the author; the assistant produces the script and the author runs it.
- It did not write the part of this system that constitutes the actual insight — the ladder
  mechanics and their parameters — which are proprietary and, as the README states, not in this
  repository at all.

## Honest note on the split

The line between "AI wrote it" and "I wrote it" is genuinely blurry for implementation code, and the
table above rounds rather than pretending to precision. The accurate summary: **the design decisions
and the review are human, the typing is substantially AI, and nothing that touches money happened
without a human deciding it should.**
