/// The event log's shape, with no storage attached — so the same indexer runs in Node against the
/// file-backed `Store` and in the dashboard against an in-memory log seeded from that file.

export interface IndexedEvent {
  blockNumber: string;
  logIndex: number;
  txHash: string;
  source: "poolManager" | "positions" | "hook";
  name: string;
  args: Record<string, string | number | boolean>;
}

/// What the indexer needs from wherever events are kept. Both implementations must honour the
/// same two rules: de-duplicate on `(blockNumber, logIndex)`, and move the cursor only together
/// with the events it describes.
export interface EventLog {
  readonly cursor: bigint;
  readonly events: readonly IndexedEvent[];
  /// Insert events and advance the cursor as one step. Returns how many were new.
  commit(events: IndexedEvent[], newCursor: bigint): number;
}

export const eventKey = (e: IndexedEvent) => `${e.blockNumber}:${e.logIndex}`;

export function compareEvents(a: IndexedEvent, b: IndexedEvent): number {
  const d = BigInt(a.blockNumber) - BigInt(b.blockNumber);
  if (d !== 0n) return d < 0n ? -1 : 1;
  return a.logIndex - b.logIndex;
}

/// JSON cannot hold a bigint, and `JSON.stringify` throws rather than guessing. Everything wide
/// becomes a decimal string; everything that fits in a double stays a number so the dashboard can
/// sort on it without parsing.
export function serialiseArgs(args: Record<string, unknown>): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  for (const [k, v] of Object.entries(args)) {
    if (typeof v === "bigint") out[k] = v.toString();
    else if (typeof v === "number" || typeof v === "boolean" || typeof v === "string") out[k] = v;
    else if (v !== undefined && v !== null) out[k] = String(v);
  }
  return out;
}
