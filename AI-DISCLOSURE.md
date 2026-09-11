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
| `arc/src/BarkerDynamicFeeHook.sol` — Sep 10 fix, branch `fix/fee-hook-clock` | **AI-diagnosed and AI-fixed**, in a second scheduled assistant session on Sep 10 without the author present. Reading the indexer's event log showed the Sep 8 "drift" had been the previous swap's own price impact, which corrected both the diagnosis (`FEEDBACK.md` §16) and the fix; the regression tests replay the Sep 8 incident. Held on a branch until the author decided (Sep 10: redeploy); the redeployment and on-chain replay were then run by the assistant in the author's session. |
| `arc/test/*.sol` | **Substantially AI-drafted.** Cases were specified by the author; the assertions on the fee premium came out of a test failing and the number being investigated. |
| `arc/script/*.s.sol`, `arc/script/lifecycle.sh` | **Substantially AI-drafted.** The forge-computes / cast-transacts split is a constraint of the chain (see `docs/environment.md`), decided by the author. |
| `keeper/src/**.ts` | **Substantially AI-drafted.** The author specified the exit rule (a one-sided ladder is done when it has fully converted, not before), the requirement that the decision be a pure function of a snapshot so it is reviewable and testable without a chain, the confirmation-count hesitation, and the store's idempotency and atomic-cursor properties — the last carried over from a production double-counting incident on another Barker service. Implementation and the v4 storage-slot arithmetic are AI. |
| `keeper/test/*.ts` | **Substantially AI-drafted.** The `poolState` fixtures are captured from a live Arc pool rather than generated, and one of them cross-checks the decoder against an independently recorded transaction. |
| `aqua/src/YieldBackedSolvencyGuard.sol` | **Substantially AI-drafted.** The author specified the cap formula `min(virtual, liquid + redeemable, allowance)`, that it must land on the reserve rather than on the resulting amount so the quote stays on the curve, and that the guard may only ever reduce. Reading `maxWithdraw` rather than `convertToAssets`, and implementing only the `view` interface so quote and swap share one selector, were AI proposals the author accepted after review. |
| `aqua/src/YieldBackedSolvencyGuard.sol` — Sep 10 change | **AI-found and AI-fixed**, in a scheduled assistant session without the author present. Scaling `balanceIn` with `balanceOut` is what the author's original "stays on the curve" requirement needed and the Sep 5 code did not deliver; the defect surfaced while the assistant was laying out the dashboard's depth chart. Pending the author's review, like everything else from that session. |
| `app/**` | **Substantially AI-drafted, Sep 10**, in the same scheduled session, against the brief in [`docs/schedule.md`](docs/schedule.md) (D6: both legs visible, legible to a judge in ten seconds, a fifth of the score). Layout, wording and the choice to reuse the keeper's indexer in the browser are the assistant's; the page reads chain data and a recorded fork trace and holds no keys. Pending the author's review. |
| `aqua/test/*.sol`, `aqua/test/mocks/*.sol` | **Substantially AI-drafted.** The mainnet-fork findings — the canonical deployment's ABI drift, `AquaOpcodes` lacking `StaticBalances` — came out of tests failing against the real chain and being investigated, not from generated commentary. |
| `README.md`, `FEEDBACK.md`, `FEEDBACK-1INCH.md`, `aqua/README.md`, `keeper/README.md`, `app/README.md`, `arc/DEPLOYMENTS.md`, `docs/*`, this file | **AI-drafted prose, author's content.** Every finding in both feedback files is something actually hit during this build. |
| `README.md` sponsor sections, `FEEDBACK.md` summary — Sep 11 | **AI-drafted** in a scheduled assistant session without the author present, from the findings already in the feedback files and `arc/DEPLOYMENTS.md`. Line references were read off the committed sources. Pending the author's review. |
| `research/arc-probe/**` | Pre-hackathon probe, AI-assisted at the time it was written (Aug 31 – Sep 2). Committed unmodified; see its README. |
| Strategy design, venue selection, licensing analysis, product decisions | **Human.** Decided before and outside the AI loop. |
| Deployment and transaction decisions | **Human.** The author decided every deployment and every on-chain run. |
| Sending testnet transactions | **Partly AI.** A number of the Arc testnet transactions were sent by the assistant from the author's session. See below. |

## What AI did not do

- It did not choose the strategy, the venues, or the product.
- It did not decide to broadcast. Every transaction was sent only after the author decided it
  should be. *Corrected Sep 11:* an earlier version of this line said the assistant never held keys
  and that the author ran every script. That was not accurate. Several Arc testnet transactions —
  deployments and lifecycle steps — were sent by the assistant itself, from the author's session,
  with the testnet deployer key the author supplied; and the Sep 8 keeper ran on a fresh key the
  assistant generated for that run, deliberately separate from the owner's. No mainnet key has been
  used, and no key is stored in this repository.
- It did not write the part of this system that constitutes the actual insight — the ladder
  mechanics and their parameters — which are proprietary and, as the README states, not in this
  repository at all.

## Honest note on the split

The line between "AI wrote it" and "I wrote it" is genuinely blurry for implementation code, and the
table above rounds rather than pretending to precision. The accurate summary: **the design decisions
and the review are human, the typing is substantially AI, and nothing that touches money happened
without a human deciding it should.**
