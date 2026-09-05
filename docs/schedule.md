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

## Plan

**Arc leg first.** It carries two of the three prize submissions (Arc and Uniswap) and it is the leg with a hard external dependency — Arc mainnet on Sep 16 — so it needs to be finished and deployable, not merely demoable.

| Day | Focus | Done when |
|---|---|---|
| **D1 — Sep 4** *(evening only)* | Repo, licensing split, probe committed as documented prior work, architecture, schedule. Environment: Arc testnet reachable, Ethereum mainnet fork pinned. | Public repo live with a real initial commit |
| **D2 — Sep 5** | Arc v4 adapter, productionised from the probe: pool creation, one-sided mint, burn, fee collection. Owner-only → proper access control. | Adapter compiles, unit tests pass against a mocked PoolManager |
| **D3 — Sep 6** | Custom v4 hook (dynamic LP fee) deployed via CREATE2 mining. Position registry + keeper skeleton. | Hook live on Arc testnet, `slot0` reads back the expected `lpFee` |
| **D4 — Sep 7** | Full lifecycle on Arc testnet with real transactions. **Check-in #1 before 20:59.** | Verified txs for open → cross → close, linked in the README |
| **D5 — Sep 8** | Minimal multi-position dashboard + backend indexer reading v4 events (`Initialize` / `Swap` / `ModifyLiquidity`). | Dashboard shows live testnet positions |
| **D6 — Sep 9** | Aqua leg starts: `Extruction` solvency guard against the official SwapVM contracts, on an Ethereum mainnet fork. | Guard caps a quote correctly in a Foundry test |
| **D7 — Sep 10** | Aqua `IMakerHooks` settlement — redeem-on-fill, redeposit-on-receive, ERC-4626 wired. **Check-in #2 before 20:59.** | A fill on the fork redeems from the vault atomically |
| **D8 — Sep 11** | Aqua demo path end to end on the fork; buffer ratio; whichever leg is behind gets the day. | Both legs demonstrable |
| **D9 — Sep 12** | Freeze. Demo video, README final, three per-sponsor integration write-ups, `FEEDBACK.md` closed out, Uniswap feedback form submitted, submission entered on the dashboard. | Submitted — **not** left for the morning of the 13th |

## The scope decision at check-in #2 (Sep 10)

If the Aqua leg is behind on D7, it gets **cut to minimum demonstrable scope** — one custom opcode plus a mainnet-fork demo — rather than allowed to eat the Arc leg's finishing time. This is decided on Sep 10, not negotiated on Sep 12.

The Arc leg is never the thing that gets cut: it carries two prize submissions and the mainnet obligation.

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
