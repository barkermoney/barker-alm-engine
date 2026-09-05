# Build schedule

Solo, 9 real days. All times **PT** (the author's local timezone, so event times need no conversion).

## Hard deadlines

| When | What | Note |
|---|---|---|
| Sep 4, 09:00 | Hacking begins | — |
| **Sep 7, 20:59** | **Project check-in #1** | Eligibility gate, not optional |
| **Sep 10, 20:59** | **Project check-in #2** | Eligibility gate + internal scope decision |
| **Sep 13, 09:00** | **Submissions due** | 12:00 EDT. The real deadline — Sep 16 is only the finale. Late submissions are not accepted. |
| Sep 14, 09:00 | Live judging (top ~20% only) | 7 minutes, live, English |
| Sep 16, 09:00 | Finale | Arc mainnet goes live the same day |
| Sep 30 | Arc mainnet deployment deadline | For the Arc "push to mainnet" bounty |

The effective window is **Sep 4 → Sep 13, 09:00**, which is nine days, not twelve. Everything below is planned backwards from check-in #1 rather than from the submission date, because the check-ins are the gates that can disqualify.

## Where we actually are

**Revised Sep 4, 23:00 PT.** The Arc leg ran about three days ahead of plan: D2, D3 and D4 all landed
on the evening of D1. Contracts written and tested, deployed to Arc testnet, and the full
take-profit lifecycle executed in six real transactions — see [`../arc/DEPLOYMENTS.md`](../arc/DEPLOYMENTS.md).

| Original day | Scope | Status |
|---|---|---|
| D1 — Sep 4 | Repo, licensing split, probe as documented prior work, architecture, environment | **done** |
| D2 — Sep 5 | v4 adapter productionised, access control, tests | **done Sep 4** — 35 tests green |
| D3 — Sep 6 | Dynamic fee hook, CREATE2 mining, position registry, keeper skeleton | **hook done and deployed Sep 4**; keeper skeleton not started |
| D4 — Sep 7 | Full lifecycle on Arc testnet with real transactions | **done Sep 4** — six verified txs, 0.081341 USDC all in |

That banks roughly three days. The plan below spends them on the **Aqua leg**, not on polish.

## Plan

The reordering rationale: the Arc leg is now the *known* one — it exists, it is deployed, and it
works on a live chain. The Aqua leg is the unknown one. It is built on SwapVM, which we have only
probed; it carries the 1inch submission on its own; and it is the leg with a copyleft licence
boundary to get right. **Risk should be retired earliest, not last**, so the Aqua leg moves forward
into the slack and the dashboard — well understood, low risk, and easy to compress — moves back.

A useful side effect: the Sep 10 scope decision was "cut Aqua if it is behind." If Aqua is
substantially done by Sep 7, that decision stops being a threat to a whole prize submission and
becomes a much cheaper choice about how much dashboard to build.

| Day | Focus | Done when |
|---|---|---|
| **D2 — Sep 5** | Aqua leg starts early. Pin the official Aqua/SwapVM contracts, stand up the mainnet fork, `Extruction` solvency guard capping quotes at `min(virtual, redeemable, allowance)`. | Guard caps a quote correctly in a Foundry test against official contracts |
| **D3 — Sep 6** | `IMakerHooks` settlement: redeem-on-fill, redeposit-on-receive, `steakUSDC` wired as the backing vault. | A fill on the fork redeems from the vault atomically |
| **D4 — Sep 7** | Aqua end to end on the fork, with the liquidity buffer ratio. **Check-in #1 before 20:59.** | Both legs demonstrable |
| **D5 — Sep 8** | Keeper loop (the piece deferred from D3) and the v4 event indexer — `Initialize` / `Swap` / `ModifyLiquidity`. | Keeper closes a testnet position unattended |
| **D6 — Sep 9** | Multi-position dashboard over the indexer, both legs visible. | Dashboard shows live testnet positions and the Aqua maker |
| **D7 — Sep 10** | Buffer, and the custom SwapVM opcode variant if the time is genuinely there. **Check-in #2 before 20:59.** | Whatever is behind gets this day |
| **D8 — Sep 11** | README, three per-sponsor integration write-ups, `FEEDBACK.md` closed out, video script and rehearsal. | Everything written except the recording |
| **D9 — Sep 12** | Record the demo video. Submit on the dashboard. | Submitted — **not** left for the morning of the 13th |

Two full days of buffer at the end. For a solo run that is the right shape; the failure mode of a
nine-day sprint is not running out of ideas, it is running out of Sunday.

## What is blocked on the author, not on the build

These cannot be done by tooling, and two of them are eligibility gates rather than deliverables.

| When | What | Why it is blocking |
|---|---|---|
| **Sep 7, 20:59** | **Check-in #1** | Hard eligibility gate. Requires an ETHGlobal login. |
| **Sep 10, 20:59** | **Check-in #2** | Same. |
| Any time before Sep 12 | Project entry on the dashboard; confirm Uniswap is selectable for a Continuity project | The one execution confirmation left from the prize plan |
| Any time before Sep 12 | Uniswap Developer Feedback Form, with the `FEEDBACK.md` link | Without it the Uniswap entry does not qualify |
| Early | Discord questions to the Arc sponsor | Answers affect how the mainnet link is delivered after the 13th |
| Sep 12 | Demo video, recorded with the author's own voice | Rules forbid AI voiceover, phone recording, and speed-ups |

The check-ins are the single largest risk on this schedule now. Everything else can be recovered from;
a missed check-in cannot.

## The scope decision at check-in #2 (Sep 10)

Originally this read: "if the Aqua leg is behind, cut it to one custom opcode plus a fork demo."
Front-loading Aqua changes what is being decided, and for the better — by Sep 10 the Aqua leg
should already be done rather than at risk, so the decision is no longer whether to abandon a whole
prize submission.

**What now gets decided on Sep 10, in this order:**

1. **How much dashboard.** The honest floor is a page that lists positions and their state. Anything
   past that is presentation, and presentation is what gets cut first.
2. **Whether to attempt the custom SwapVM opcode variant.** 1inch explicitly permits redeploying a
   modified SwapVM, and doing so is a differentiator rather than a requirement — the official
   extension points (`Extruction`, `IMakerHooks`) already satisfy the brief. Attempt it only if D7
   is genuinely free.
3. **Only if Aqua has slipped badly:** the original cut still stands as the fallback.

The Arc leg is never the thing that gets cut. It carries two of the three prize submissions and the
mainnet obligation, and as of Sep 4 it is already deployed and verified — so cutting it would mean
discarding finished work, which is never the right trade.

Whatever is decided is decided **on Sep 10**, not renegotiated on the 12th. The point of naming a
decision date is to stop the last two days from being spent deciding instead of finishing.

## After submission

| When | What |
|---|---|
| Sep 14 | Live judging, if we place in the top 20% |
| **Sep 16** | Arc mainnet is live — deploy, execute one real transaction, add the verified tx and addresses to this README and to the ETHGlobal showcase page |
| Sep 30 | Hard deadline for the Arc mainnet requirement |

## Prize submissions (max 3 per project)

| Sponsor | Track | What it needs from us |
|---|---|---|
| **1inch** | "Build an Aqua App" — Continuity ($1,500 / $500) | Official Aqua/SwapVM contracts **required**, though redeploying a *modified* SwapVM is explicitly allowed. On-chain token transfer shown in the demo — **local forks are acceptable**. Modified opcodes and custom instructions are explicitly invited, not merely tolerated. Proper commit history, no single-commit final day. |
| **Arc (Circle)** | Primary: "Launch on Arc Testnet & Push to Mainnet" — Continuity ($1,000 / $500). Also qualifies for "Best DeFi or Agentic Application" — Continuity ($1,666) | Functional MVP **and an architecture diagram**, a video demo covering effective use of Circle tools, and a repo link. Mainnet requirement is **"deployed or deployment-ready by September 30"** — so submitting on the 13th, before Arc mainnet exists on the 16th, is anticipated by the rules. The submission must state explicitly which bounty is targeted. |
| **Uniswap Foundation** | "Best Uniswap Stack Contribution" — Continuity ($1,000 × 2) | Three things, all mandatory: a public repo with open-source code, **`FEEDBACK.md`**, and a completed [Developer Feedback Form](https://developers.uniswap.org/hackathon-feedback). Plus: the README must point clearly at the relevant contracts **and lines of code**. No chain restriction; new v4 hooks are explicitly welcomed. |

Each sponsor gets its own integration write-up and its own feedback. Multiple sub-bounties from one sponsor consume only one of the three slots.

Tailwind worth noting: Uniswap has announced it is bringing v4 to Arc mainnet for the September launch, so the Arc leg and the Uniswap submission point at the same future rather than at two different ones.
