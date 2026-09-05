# AI usage disclosure

ETHOnline 2026 asks entrants to disclose AI assistance. This is that disclosure, kept current as the build proceeds.

## Tooling

**Claude Code** (Anthropic) was the primary assistant, used interactively from a terminal. No other code-generating AI tools were used.

## What AI was used for

| Area | Role |
|---|---|
| Solidity — hook, PoolManager integration, one-sided position management | **Assisted.** Architecture and the strategy design are the author's; AI drafted implementations against written specs and iterated on test failures. Every contract was read line by line before being committed. |
| Foundry tests | **Assisted**, heavily. Test cases were specified by the author, drafted by AI. |
| TypeScript app / dashboard | **Assisted**, majority AI-drafted from a spec. |
| Documentation, README, this file | **Assisted.** Structure and claims are the author's; prose drafted with AI and edited. |
| Strategy design, venue selection, licensing analysis, product decisions | **Human.** These were decided before and outside the AI loop. |
| On-chain transactions, key handling, deployment | **Human.** Every transaction that moves real funds is reviewed and signed by the author. AI produces the script; it does not hold keys or broadcast. |

## Specs and prompts

Working specs handed to the assistant are kept in [`docs/specs/`](docs/specs/) rather than discarded, so the instruction → output path is inspectable.

## What AI did not do

- It did not choose the strategy, the venues, or the product.
- It did not sign, broadcast, or hold keys for any transaction.
- It did not write the parts of this system that constitute the actual insight — the take-profit / bid ladder mechanics and their parameters — which are proprietary and, per the README, not in this repository at all.

## Honest note on the split

The line between "AI wrote it" and "I wrote it" is genuinely blurry for the implementation code, and this table rounds rather than pretends to precision. The accurate summary: **the design decisions are human, the typing is substantially AI, and the review is human on every line that touches money.**
