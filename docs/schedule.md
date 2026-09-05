# Build schedule

Solo, 9 real days. All times **PT** (the author's local timezone, so event times need no conversion).

## Hard deadlines

| When | What | Note |
|---|---|---|
| Sep 4, 09:00 | Hacking begins | — |
| Sep 7, 20:59 | Project check-in #1 | Progress touchpoint, prompted by the dashboard — not a gate. See below. |
| Sep 10, 20:59 | Project check-in #2 | Same, and the day the internal scope decision is made |
| **Sep 13, 09:00** | **Submissions due** | 12:00 EDT. The real deadline — Sep 16 is only the finale. Late submissions are not accepted. |
| Sep 14, 09:00 | Live judging (top ~20% only) | 7 minutes: **4 minutes demo + 3 minutes Q&A**, live, English. Round 1 has no bearing on partner prizes — most prize money goes to projects that never advance. |
| Sep 16, 09:00 | Finale | Arc mainnet goes live the same day |
| Sep 30 | Arc mainnet deployment deadline | For the Arc "push to mainnet" bounty |

The effective window is **Sep 4 → Sep 13, 09:00** — nine days, not twelve. Everything below is planned backwards from that submission deadline, which is the one date with no recovery from missing it.

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

**One caveat on compressing the dashboard.** The official judging criteria are Technicality,
Originality, Practicality, **Usability (UI/UX/DX)** and WOW Factor — five categories, so the
interface is a fifth of the score, not a nice-to-have. D6 should produce something a judge can look
at and understand in ten seconds, not a debug view. If anything gets cut on Sep 10 it should be
breadth of features, not the legibility of the one screen that gets demoed.

## What is blocked on the author, not on the build

| When | What | Why it is blocking |
|---|---|---|
| Sep 7 / Sep 10, 20:59 | Project check-ins | Progress touchpoints; the dashboard prompts when it is time. See the note below. |
| When submissions open | Set submission type to **Top 10 Finalist & Partner Prizes** (decided Sep 5) | The radio lives on the prize step, which the site keeps disabled until submissions open. Round 1 async judging has no bearing on partner prizes, so opting in costs nothing but the Sep 14 live slot if we place. |
| When submissions open | Select the three partner prizes: 1inch, Arc, Uniswap Foundation | Confirmed selectable — Uniswap's $2,000 track is labelled "only available to Continuity Track participants" |
| Any time before Sep 12 | Uniswap Developer Feedback Form, with the `FEEDBACK.md` link | Without it the Uniswap entry does not qualify |
| Sep 12 | Demo video, recorded with the author's own voice | Rules forbid AI voiceover, phone recording, speed-ups, and anything under 720p or over 4 minutes |

### On the check-ins — corrected Sep 4

An earlier version of this document called the check-ins hard eligibility gates that could not be
recovered from. **That was our assumption, not the rules.** The official wording is:

> "Check-ins are in place to help track your progress and for us to offer support. The check-in
> process is simple: your Hacker Dashboard will notify you when it's time to check in […] Check-ins
> allow you to highlight any blockers, ask for help, or simply confirm that everything is on track."

Supportive, not punitive, and nothing anywhere ties them to disqualification. They are also *pull*
rather than *push* — the dashboard notifies, so there is nothing to submit ahead of time, which is
why no check-in action appears on it today. Do them when prompted; do not plan around them as if
they were the submission deadline.

The one genuinely unrecoverable deadline is **Sep 13, 12:00 EDT**. Late submissions are not accepted.

### Two questions we were going to ask the Arc sponsor, answered from the published rules

**"Submissions close Sep 13 but Arc mainnet launches Sep 16 — how do we deliver the mainnet link
afterwards?"** No special channel is needed. The Arc brief asks for a project "deployed **or
deployment-ready** on Arc mainnet by September 30", so being deployment-ready at submission already
satisfies it; and the submission form states plainly that *"you can still update your project after
submitting."* The route is therefore: deploy on Sep 16, update the README and the project entry.

**"Can one Continuity project be considered for both Arc sub-bounties at once?"** Yes. The official
rules: *"If a partner has multiple tracks, you can be eligible for all of them while only counting
as 1 Partner Prize."* Both Arc tracks we target are Continuity-marked, and together they consume one
of our three slots.

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
