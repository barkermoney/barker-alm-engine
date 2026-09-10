/// The solvency guard's effect on a quote, drawn. Same arithmetic as SwapVM's `XYCSwap` opcode
/// (`amountOut = amountIn · balanceOut / (balanceIn + amountIn)`) applied to the reserves each
/// version of the guard hands it. The "now" curve is the one asserted through the real router in
/// `aqua/test/SolvencyGuardOnSwapVM.t.sol`, `test_guardKeepsThePriceAndTrimsOnlyTheDepth`.

export function xyc(balanceIn: number, balanceOut: number, amountIn: number): number {
  return (amountIn * balanceOut) / (balanceIn + amountIn);
}

export interface Quotes {
  /// No guard: the strategy prices against its virtual reserves.
  unguarded: number;
  /// The Sep 5 guard: balanceOut capped, balanceIn left alone — the price moved.
  sep5: number;
  /// The Sep 10 guard: both reserves scaled by the same factor — the depth moved, the price did not.
  guarded: number;
}

export function quotes(virtualReserve: number, backing: number, amountIn: number): Quotes {
  const capped = Math.min(virtualReserve, backing);
  const scaledIn = (virtualReserve * capped) / virtualReserve;
  return {
    unguarded: xyc(virtualReserve, virtualReserve, amountIn),
    sep5: xyc(virtualReserve, capped, amountIn),
    guarded: xyc(scaledIn, capped, amountIn),
  };
}

const W = 600;
const H = 280;
const PAD = { l: 56, r: 16, t: 28, b: 34 };

export function depthChart(virtualReserve: number, backing: number, size: number, xMax: number): string {
  const top = Math.max(xyc(virtualReserve, virtualReserve, xMax), backing) * 1.1;
  const x = (v: number) => PAD.l + (v / xMax) * (W - PAD.l - PAD.r);
  const y = (v: number) => H - PAD.b - (v / top) * (H - PAD.t - PAD.b);

  const N = 120;
  const pts = (f: (a: number) => number) =>
    Array.from({ length: N + 1 }, (_, i) => {
      const a = (i / N) * xMax;
      return `${x(a).toFixed(1)},${y(f(a)).toFixed(1)}`;
    }).join(" ");

  const q = (a: number) => quotes(virtualReserve, backing, a);

  // Where the unguarded strategy promises more than the vault can produce.
  const over: string[] = [];
  for (let i = 0; i <= N; i++) {
    const a = (i / N) * xMax;
    const u = q(a).unguarded;
    if (u > backing) over.push(`${x(a).toFixed(1)},${y(u).toFixed(1)}`);
  }
  let overPoly = "";
  if (over.length > 1) {
    const first = over[0]!.split(",")[0];
    const last = over[over.length - 1]!.split(",")[0];
    overPoly = `<polygon class="over" points="${first},${y(backing).toFixed(1)} ${over.join(" ")} ${last},${y(backing).toFixed(1)}" />`;
  }

  const ticksX = niceTicks(xMax, 4).map(
    (t) => `<g class="tick"><line x1="${x(t)}" x2="${x(t)}" y1="${H - PAD.b}" y2="${H - PAD.b + 4}"/><text x="${x(t)}" y="${H - PAD.b + 17}" text-anchor="middle">${compact(t)}</text></g>`,
  );
  const ticksY = niceTicks(top, 4).map(
    (t) => `<g class="tick"><line class="grid" x1="${PAD.l}" x2="${W - PAD.r}" y1="${y(t)}" y2="${y(t)}"/><text x="${PAD.l - 8}" y="${y(t) + 4}" text-anchor="end">${compact(t)}</text></g>`,
  );

  const s = q(size);
  const marker = `
    <line class="marker" x1="${x(size)}" x2="${x(size)}" y1="${PAD.t}" y2="${H - PAD.b}" />
    <circle class="dot unguarded" cx="${x(size)}" cy="${y(s.unguarded)}" r="4" />
    <circle class="dot sep5" cx="${x(size)}" cy="${y(s.sep5)}" r="3.5" />
    <circle class="dot guarded" cx="${x(size)}" cy="${y(s.guarded)}" r="4.5" />`;

  return `
  <svg viewBox="0 0 ${W} ${H}" class="depth" role="img" aria-label="Quoted USDC out against USDT in, with and without the solvency guard">
    ${ticksY.join("")}
    ${overPoly}
    <line class="backing" x1="${PAD.l}" x2="${W - PAD.r}" y1="${y(backing)}" y2="${y(backing)}" />
    <text class="backing-label" x="${W - PAD.r - 4}" y="${y(backing) - 6}" text-anchor="end">what the vault can pay · ${compact(backing)}</text>
    <polyline class="curve unguarded" points="${pts((a) => q(a).unguarded)}" />
    <polyline class="curve sep5" points="${pts((a) => q(a).sep5)}" />
    <polyline class="curve guarded" points="${pts((a) => q(a).guarded)}" />
    ${marker}
    <line class="axis" x1="${PAD.l}" x2="${W - PAD.r}" y1="${H - PAD.b}" y2="${H - PAD.b}" />
    ${ticksX.join("")}
    <text class="axis-label" x="${W - PAD.r}" y="${H - 2}" text-anchor="end">USDT the taker sells →</text>
    <text class="axis-label" x="4" y="12">USDC out ↑</text>
  </svg>`;
}

function niceTicks(max: number, count: number): number[] {
  const raw = max / count;
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? raw;
  const out: number[] = [];
  for (let t = 0; t <= max + 1e-9; t += step) out.push(t);
  return out;
}

export function compact(v: number): string {
  if (v >= 1e6) return `${+(v / 1e6).toFixed(v % 1e6 === 0 ? 0 : 2)}M`;
  if (v >= 1e3) return `${+(v / 1e3).toFixed(v >= 1e5 ? 0 : 1)}k`;
  return `${+v.toFixed(2)}`;
}
