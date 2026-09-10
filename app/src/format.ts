export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/// Integer token amount → human string, trimmed. Exact: works on the bigint, never through a float.
export function units(raw: bigint | string, decimals: number, maxFrac = 6): string {
  const v = BigInt(raw);
  const neg = v < 0n;
  const abs = neg ? -v : v;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  let frac = (abs % base).toString().padStart(decimals, "0").slice(0, maxFrac).replace(/0+$/, "");
  const w = whole.toLocaleString("en-US");
  return `${neg ? "−" : ""}${w}${frac ? `.${frac}` : ""}`;
}

export function num(v: number, frac = 2): string {
  return v.toLocaleString("en-US", { maximumFractionDigits: frac, minimumFractionDigits: 0 });
}

export function pct(v: number, frac = 2, signed = true): string {
  const s = (v * 100).toFixed(frac);
  const n = Number(s);
  if (!signed) return `${s}%`;
  return `${n > 0 ? "+" : n < 0 ? "−" : ""}${Math.abs(n).toFixed(frac)}%`;
}

/// A price small enough to need significant figures rather than decimals (BPROBE ≈ 1e-4 USDC).
export function sig(v: number, digits = 4): string {
  if (v === 0) return "0";
  if (Math.abs(v) >= 1) return num(v, digits);
  return v.toPrecision(digits).replace(/e-(\d+)/, (_, e) => `×10⁻${sup(e)}`);
}

function sup(s: string): string {
  const map: Record<string, string> = { "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹" };
  return s.split("").map((c) => map[c] ?? c).join("");
}

export function shortAddr(a: string): string {
  return a.length > 12 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a;
}

export function ago(ms: number): string {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  return `${Math.round(s / 60)}m ago`;
}
