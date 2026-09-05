# License notice for `aqua/`

> **Powered by SwapVM — © Degensoft Ltd 2025**

**This directory is NOT MIT-licensed.** The repository root `LICENSE` (MIT) does not apply here.

Code in `aqua/` is licensed under **SwapVM-1.1** (`LicenseRef-Degensoft-SwapVM-1.1`), with **Aqua-Source-1.1** applying to anything deriving from Aqua Core/Router/App. Full texts are vendored in [`LICENSES/`](LICENSES/) so the terms travel with the code:

- [`LICENSES/SwapVM-1.1.txt`](LICENSES/SwapVM-1.1.txt)
- [`LICENSES/Aqua-Source-1.1.txt`](LICENSES/Aqua-Source-1.1.txt)

Both are Degensoft Ltd **source-available copyleft** licenses, not open-source licenses.

## Why the directory split exists

The line that matters is §1.7's definition of *Modify*, which includes plugging into the **same runtime / EVM address space** — static or dynamic linking, `delegatecall`, proxies. §3.3 says the converse: code that merely **calls** the Licensed Work, or only implements its interfaces, is not a derivative work.

So:

| | License | Because |
|---|---|---|
| `aqua/` — SwapVM extensions, `Extruction` guards, `IMakerHooks` implementations, any redeployed opcode variant | **SwapVM-1.1** | Lives inside SwapVM's address space → a Modification under §1.7 |
| Everything else — Arc/Uniswap v4 leg, orchestration, app layer | **MIT** | Independent works that only form calldata and read state → §3.3 |

**Do not move files across this boundary without re-deciding which license follows them.** Copying an `aqua/` file into `arc/` does not make it MIT.

## Obligations we are meeting here

Per §3.1, modifications must:

- **A** — be released under this same license (this directory is);
- **C** — carry prominent attribution *"Powered by SwapVM — © Degensoft Ltd 2025"* in the repository README and UI (it is in the root README, this notice, and the dashboard footer);
- **D** — state what was changed and when (each file in this directory carries a change header; see also the git history).

## Commercial triggers — noted, not currently crossed

§4 makes non-commercial use — explicitly including **hackathons**, prototyping, and research — free of charge, subject to §3 for modifications. That is what this repository is.

Commercial use is separately gated by §5.2 triggers: **Charged Fees > US$100,000** in any rolling 12-month period *or any single calendar month*, or **Liquidity Under Control > US$10,000,000**. §5.3 currently waives enforcement of those triggers for market-making, routing, aggregation, and arbitrage — but that waiver "is not a license, creates no reliance rights, and is revocable at any time," with a 10-day wind-down on notice.

Anyone forking this for production should read §5 rather than assume the waiver holds.
