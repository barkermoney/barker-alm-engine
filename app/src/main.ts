import "./style.css";
import { ARC, ArcFeed, type ArcState, type PositionView } from "./arc";
import { AquaFeed, STEAK_USDC, loadTrace, type Trace, type VaultState } from "./aqua";
import { compact, depthChart, quotes } from "./depth";
import { ago, esc, num, pct, shortAddr, sig, units } from "./format";

const $ = <T extends HTMLElement>(sel: string) => document.querySelector<T>(sel)!;

const tx = (h: string) => `${ARC.explorer}/tx/${h}`;
const addr = (a: string) => `${ARC.explorer}/address/${a}`;
const etherscan = (a: string) => `https://etherscan.io/address/${a}`;

/// token1 per token0 in display units. Ratios of these are decimal-free, which is what every
/// percentage on the page is.
const priceAt = (tick: number, d0: number, d1: number) => Math.pow(1.0001, tick) * Math.pow(10, d0 - d1);

// ---------------------------------------------------------------------------------------------
// Arc leg
// ---------------------------------------------------------------------------------------------

function renderArc(s: ArcState): void {
  const sync = s.syncing
    ? `<span class="chip warn">indexing · block ${num(Number(s.cursor), 0)}</span>`
    : s.error
      ? `<span class="chip bad" title="${esc(s.error)}">Arc RPC unreachable · retrying</span>`
      : s.head
        ? `<span class="chip ok">Arc testnet · block ${num(Number(s.head), 0)}</span>`
        : `<span class="chip">Arc testnet · connecting</span>`;
  $("#arc-chip").innerHTML = sync;

  const total = s.positions.length;
  const converted = s.positions.filter((p) => p.progress >= 1).length;
  const byKeeper = s.positions.filter((p) => p.closedByKeeper).length;
  const open = s.positions.filter((p) => !p.summary.closed).length;

  $("#arc-kpis").innerHTML = [
    kpi(String(total), "ladders opened", `on the registry at <a href="${addr(ARC.positions)}" target="_blank" rel="noopener">${shortAddr(ARC.positions)}</a>`),
    kpi(`${converted}/${total}`, "fully converted", "sold into strength, returned in USDC"),
    kpi(String(byKeeper), "closed unattended", "by the keeper, on its own key"),
    kpi(String(open), "open now", open ? "watched live below" : "nothing at risk right now"),
  ].join("");

  const pool = s.pools[0];
  $("#arc-pool").innerHTML = pool
    ? `<div class="pool">
        <div class="pool-pair">${esc(pool.token0.symbol)} / ${esc(pool.token1.symbol)}</div>
        <div class="pool-meta">
          <span>Uniswap v4 · dynamic fee</span>
          <span title="slot0.lpFee, read through extsload. The hook adds any surge per swap as an override, which is not persisted to slot0; the fee each swap paid is in the log below, from the Swap event.">base fee <b>${pool.lpFee === undefined ? "…" : pct(pool.lpFee / 1e6, 2, false)}</b></span>
          <span>tick <b>${pool.tick === undefined ? "…" : num(pool.tick, 0)}</b></span>
          <span>1 ${esc(pool.token0.symbol)} = <b>${pool.tick === undefined ? "…" : sig(priceAt(pool.tick, pool.token0.decimals, pool.token1.decimals))}</b> ${esc(pool.token1.symbol)}</span>
          <span>hook <a href="${addr(pool.hooks)}" target="_blank" rel="noopener">${shortAddr(pool.hooks)}</a></span>
        </div>
      </div>`
    : "";

  $("#arc-positions").innerHTML = s.positions.length
    ? s.positions.map(positionCard).join("")
    : `<p class="empty">No positions yet. Open one with <code>arc/script/lifecycle.sh</code>.</p>`;

  const surged = s.fees.some((f) => (f.surge ?? 0) > 0);
  $("#arc-fees").innerHTML = s.fees.length
    ? `<table class="fees">
        <thead><tr><th>Swap</th><th title="Swap.fee from the PoolManager's own event — the hook's override when one is set">Fee charged</th><th>of which surge</th><th>Ticks moved since last swap</th></tr></thead>
        <tbody>${s.fees
          .map(
            (f) => `<tr class="${(f.surge ?? 0) > 0 ? "flag" : ""}">
              <td><a href="${tx(f.txHash)}" target="_blank" rel="noopener">block ${num(Number(f.blockNumber), 0)}</a></td>
              <td><b>${pct(f.fee / 1e6, 2, false)}</b></td>
              <td>${f.surge === undefined ? "—" : pct(f.surge / 1e6, 2, false)}</td>
              <td>${f.tickMove === undefined ? "—" : num(f.tickMove, 0)}</td></tr>`,
          )
          .join("")}</tbody></table>
      ${surged ? `<p class="note">A surge on the first swap after four quiet days is our hook's known defect, not volatility: it measures price drift without normalising for elapsed time. Documented, tested and reported in <a href="https://github.com/barkermoney/barker-alm-engine/blob/main/FEEDBACK.md" target="_blank" rel="noopener">FEEDBACK.md §16</a>.</p>` : ""}`
    : `<p class="empty">No swaps through the hook yet.</p>`;

  $("#arc-updated").textContent = s.lastUpdate ? `updated ${ago(s.lastUpdate)} · refreshes every 5s` : "";
}

function kpi(value: string, label: string, sub: string): string {
  return `<div class="kpi"><div class="kpi-v">${value}</div><div class="kpi-l">${label}</div><div class="kpi-s">${sub}</div></div>`;
}

function positionCard(p: PositionView): string {
  const { summary: s, pool } = p;
  const d0 = pool.token0.decimals;
  const d1 = pool.token1.decimals;
  const spot = priceAt(p.tickAtOpen, d0, d1);
  const lo = priceAt(s.tickLower, d0, d1) / spot - 1;
  const hi = priceAt(s.tickUpper, d0, d1) / spot - 1;
  const upper = s.side === "Upper";
  const fundToken = upper ? pool.token0 : pool.token1;

  const status = {
    waiting: { cls: "wait", text: upper ? "Waiting · price below the ladder" : "Waiting · price above the ladder" },
    converting: { cls: "live", text: `Converting · ${Math.round(p.progress * 100)}%` },
    converted: { cls: "live", text: "Converted · keeper confirming" },
    closed: p.closedByKeeper
      ? { cls: "done", text: "Closed by keeper" }
      : { cls: "done", text: p.closedBy ? "Closed by owner" : "Closed" },
  }[p.status];

  // Where the marker sits: live tick for an open ladder, the tick it was exited at for a closed one.
  const markTick = s.closed ? p.tickAtClose : pool.tick;
  const mark = markTick === undefined ? undefined : priceAt(markTick, d0, d1) / spot - 1;

  let result = "";
  if (s.closed && s.amount0Out !== undefined && s.amount1Out !== undefined) {
    const funded = Number(s.amountFunded) / 10 ** (upper ? d0 : d1);
    const got0 = Number(s.amount0Out) / 10 ** d0;
    const got1 = Number(s.amount1Out) / 10 ** d1;
    // Realised price, token1 per token0, counting any unconverted remainder at the exit tick.
    const exit = p.tickAtClose === undefined ? spot : priceAt(p.tickAtClose, d0, d1);
    const realised = upper ? (got1 + got0 * exit) / funded : funded / (got0 + got1 / exit);
    const vsSpot = upper ? realised / spot - 1 : spot / realised - 1;
    const geo = Math.sqrt(priceAt(s.tickLower, d0, d1) * priceAt(s.tickUpper, d0, d1));
    const vsGeo = upper ? realised / geo - 1 : geo / realised - 1;
    result = `
      <div><dt>Returned</dt><dd>${units(s.amount1Out, d1)} ${esc(pool.token1.symbol)}${s.amount0Out !== "0" ? ` + ${units(s.amount0Out, d0, 4)} ${esc(pool.token0.symbol)}` : ""}</dd></div>
      <div><dt>vs. spot at open</dt><dd class="${vsSpot >= 0 ? "good" : "badv"}">${pct(vsSpot)}</dd></div>
      <div><dt>vs. range mid-price</dt><dd title="Realised price over the range's geometric mean. For a ladder filled at 0.30%, the clean formula fee/(1−fee) gives +0.3009%.">${pct(vsGeo, 3)}</dd></div>`;
  } else if (p.feesOwed) {
    result = `
      <div><dt>Converted</dt><dd>${Math.round(p.progress * 100)}%</dd></div>
      <div><dt>Fees owed</dt><dd>${units(p.feesOwed[0], d0, 4)} ${esc(pool.token0.symbol)} · ${units(p.feesOwed[1], d1)} ${esc(pool.token1.symbol)}</dd></div>`;
  }

  const closer = p.closedBy
    ? ` by <a href="${addr(p.closedBy)}" target="_blank" rel="noopener">${shortAddr(p.closedBy)}</a>${p.closedByKeeper ? " <span class=\"tag\">keeper</span>" : s.owner.toLowerCase() === p.closedBy.toLowerCase() ? " <span class=\"tag\">owner</span>" : ""}`
    : "";

  return `
  <article class="pos">
    <header>
      <span class="pos-id">#${esc(s.positionId)}</span>
      <span class="pos-kind">${upper ? "Take-profit ladder · sells above spot" : "Buy ladder · buys below spot"}</span>
      <span class="pill ${status.cls}">${status.text}</span>
    </header>
    ${rangeBar(lo, hi, mark, s.closed ? "exit" : "now", p.progress)}
    <dl class="facts">
      <div><dt>Range</dt><dd>${pct(lo)} … ${pct(hi)}</dd></div>
      <div><dt>Funded, one-sided</dt><dd>${units(s.amountFunded, upper ? d0 : d1, 2)} ${esc(fundToken.symbol)}</dd></div>
      ${result}
    </dl>
    <footer>
      <a href="${tx(s.openTx)}" target="_blank" rel="noopener">opened · block ${num(Number(s.openedAtBlock), 0)}</a>
      ${s.closeTx ? `<span>→</span><a href="${tx(s.closeTx)}" target="_blank" rel="noopener">closed · block ${num(Number(s.closedAtBlock), 0)}</a>${closer}` : ""}
    </footer>
  </article>`;
}

/// A price axis in percent from the spot at open: the ladder as a band, spot as a tick, and the
/// live (or exit) price as a marker. The fill inside the band is conversion progress.
function rangeBar(lo: number, hi: number, mark: number | undefined, markLabel: string, progress: number): string {
  const W = 560;
  const H = 70;
  const L = 14;
  const R = W - 14;
  const vals = [0, lo, hi, ...(mark === undefined ? [] : [mark])];
  const span = Math.max(...vals) - Math.min(...vals) || 0.01;
  const min = Math.min(...vals) - span * 0.12;
  const max = Math.max(...vals) + span * 0.12;
  const x = (v: number) => L + ((v - min) / (max - min)) * (R - L);
  const y = 32;
  const fillW = (x(hi) - x(lo)) * Math.min(Math.max(progress, 0), 1);

  return `
  <svg viewBox="0 0 ${W} ${H}" class="rangebar" role="img" aria-label="Range from ${pct(lo)} to ${pct(hi)} of spot">
    <line class="rb-axis" x1="${L}" x2="${R}" y1="${y}" y2="${y}" />
    <rect class="rb-band" x="${x(lo)}" y="${y - 9}" width="${x(hi) - x(lo)}" height="18" rx="3" />
    <rect class="rb-fill" x="${x(lo)}" y="${y - 9}" width="${fillW}" height="18" rx="3" />
    <line class="rb-spot" x1="${x(0)}" x2="${x(0)}" y1="${y - 14}" y2="${y + 14}" />
    <text class="rb-t" x="${x(0)}" y="${H - 4}" text-anchor="middle">spot at open</text>
    <text class="rb-t" x="${x(lo)}" y="${y - 14}" text-anchor="middle">${pct(lo)}</text>
    <text class="rb-t" x="${x(hi)}" y="${y - 14}" text-anchor="middle">${pct(hi)}</text>
    ${
      mark === undefined
        ? ""
        : `<path class="rb-mark" d="M ${x(mark)} ${y + 11} l -5 8 h 10 z" /><text class="rb-t strong" x="${x(mark)}" y="${H - 4}" text-anchor="middle">${markLabel} ${pct(mark)}</text>`
    }
  </svg>`;
}

// ---------------------------------------------------------------------------------------------
// Aqua leg
// ---------------------------------------------------------------------------------------------

function renderVault(v: VaultState): void {
  $("#eth-chip").innerHTML = v.error && !v.block
    ? `<span class="chip bad" title="${esc(v.error)}">Ethereum RPC unreachable</span>`
    : v.block
      ? `<span class="chip ok">Ethereum mainnet · block ${num(Number(v.block), 0)}</span>`
      : `<span class="chip">Ethereum mainnet · connecting</span>`;

  $("#aqua-kpis").innerHTML = [
    kpi(v.apy === undefined ? "…" : pct(v.apy, 2, false), "steakUSDC APY", "7-day share price, annualised, live"),
    kpi(v.totalAssets === undefined ? "…" : `$${compact(Number(v.totalAssets) / 1e6)}`, "vault size", `Steakhouse on MetaMorpho · <a href="${etherscan(STEAK_USDC)}" target="_blank" rel="noopener">${shortAddr(STEAK_USDC)}</a>`),
    kpi(v.sharePrice === undefined ? "…" : sig(v.sharePrice, 7), "USDC per share", "what the maker's position is worth"),
  ].join("");
}

let trace: Trace | undefined;
const VIRTUAL = 10_000_000;

function renderDepth(): void {
  const backing = Number($<HTMLInputElement>("#backing").value);
  const size = Number($<HTMLInputElement>("#size").value);
  $("#backing-v").textContent = `$${compact(backing)}`;
  $("#size-v").textContent = `${compact(size)} USDT`;
  $("#depth-chart").innerHTML = depthChart(VIRTUAL, backing, size, 1_000_000);

  const q = quotes(VIRTUAL, backing, size);
  // Marginal price = balanceOut / balanceIn of the reserves the curve actually runs on.
  const marginal = { unguarded: 1, sep5: Math.min(backing, VIRTUAL) / VIRTUAL, guarded: 1 };
  const row = (cls: keyof typeof marginal, name: string, out: number, verdict: string, ok: boolean) => `
    <tr class="${cls}"><td><i></i>${name}</td><td>${marginal[cls].toFixed(4)}</td><td>${num(out, 0)} USDC</td><td>${size ? (out / size).toFixed(4) : "—"}</td><td class="${ok ? "good" : "badv"}">${verdict}</td></tr>`;
  $("#depth-readout").innerHTML = `
    <table class="readout">
      <thead><tr><th>Strategy</th><th title="USDC per USDT for the first unit — the curve's own price">Price at the margin</th><th>Quote at this size</th><th>Avg price</th><th></th></tr></thead>
      <tbody>
        ${row("unguarded", "No guard", q.unguarded, q.unguarded > backing ? "cannot be paid — fill reverts, taker eats the gas" : "payable", q.unguarded <= backing)}
        ${row("sep5", "Guard, Sep 5", q.sep5, "payable, at a price nobody takes", false)}
        ${row("guarded", "Guard, now", q.guarded, "payable, on the strategy's own curve", true)}
      </tbody>
    </table>`;
}

function renderTrace(t: Trace | undefined): void {
  if (!t) {
    $("#trace").innerHTML = `<p class="empty">No recorded run found. Record one with <code>RECORD_TRACE=true forge test --match-test test_recordDashboardTrace</code> in <code>aqua/</code>.</p>`;
    return;
  }
  const usd = (raw: string) => units(raw, 6, 0);
  const label: Record<string, string> = {
    deposit: "Deposit",
    quote: "Quote",
    "fill-out": "Fill · pay out",
    "fill-in": "Fill · take in",
    accrue: "30 days later",
  };
  const taker = (s: Trace["steps"][number]) => {
    if (s.id === "deposit") return "—";
    if (s.id === "quote" || s.id === "accrue") return `quoted <b>${usd(s.amountOut)} USDC</b> for ${usd(s.amountIn)} USDT`;
    if (s.id === "fill-out") return `paid <b>${usd(s.amountOut)} USDC</b> for ${usd(s.amountIn)} USDT`;
    return `paid <b>${usd(s.amountOut)} USDT</b> for ${usd(s.amountIn)} USDC`;
  };

  $("#trace").innerHTML = `
    <p class="lede">Recorded on an Ethereum mainnet fork at block <b>${num(t.recordedAtBlock, 0)}</b>: real USDC and USDT, the live steakUSDC vault, an unmodified <code>SwapVMRouter</code>. Asked for twice its backing, the same strategy would have promised <b class="badv">${usd(t.unguardedQuote)} USDC</b> without the guard; with it, it quoted <b class="good">${usd(t.guardedQuote)}</b>.</p>
    <div class="table-wrap"><table class="trace">
      <thead><tr><th>Step</th><th>Taker</th><th>Maker wallet · idle USDC</th><th>Maker in steakUSDC</th></tr></thead>
      <tbody>${t.steps
        .map(
          (s) => `<tr>
            <td><div class="step">${label[s.id] ?? s.id}</div><div class="muted small">${esc(s.text)}</div></td>
            <td>${taker(s)}</td>
            <td class="zero">${usd(s.makerWalletUsdc)}</td>
            <td>${usd(s.makerVaultUsdc)}</td></tr>`,
        )
        .join("")}</tbody>
    </table></div>
    <p class="note">Idle USDC stays at zero through every fill: payouts are redeemed from the vault inside the swap, receipts are deposited before it ends. Reproduce with <code>RECORD_TRACE=true ETHEREUM_RPC_URL=https://eth.drpc.org forge test --match-test test_recordDashboardTrace</code> in <code>aqua/</code>.</p>`;
}

// ---------------------------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------------------------

async function main(): Promise<void> {
  for (const id of ["#backing", "#size"]) $(id).addEventListener("input", renderDepth);
  renderDepth();

  const arc = new ArcFeed(renderArc);
  const aqua = new AquaFeed(renderVault);

  await arc.seed();
  trace = await loadTrace();
  renderTrace(trace);

  const loopArc = async () => {
    await arc.refresh();
    setTimeout(loopArc, 5_000);
  };
  const loopAqua = async () => {
    await aqua.refresh();
    setTimeout(loopAqua, 60_000);
  };
  void loopArc();
  void loopAqua();
}

void main();
