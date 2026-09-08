import { mkdirSync, readFileSync, renameSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

/// An append-only event log with a cursor, on disk as one JSON file.
///
/// Two properties matter more than the storage engine, and both are scars from a production
/// incident on another Barker service where a replayed window double-counted hourly volume:
///
///   1. **Events are keyed by `(blockNumber, logIndex)` and de-duplicated on insert.** Re-indexing
///      a range that was already indexed is a no-op, so a crash between "wrote data" and "wrote
///      cursor" costs a redundant fetch and nothing else.
///   2. **The cursor is only advanced as part of the same atomic write as the data it describes.**
///      Write to a temp file, then rename — rename is atomic on POSIX, so a reader never observes
///      a cursor that is ahead of the events behind it.
///
/// The failure mode being designed out is not "the file is corrupt". It is "the numbers are
/// plausible and wrong".

export interface IndexedEvent {
  blockNumber: string;
  logIndex: number;
  txHash: string;
  source: "poolManager" | "positions" | "hook";
  name: string;
  args: Record<string, string | number | boolean>;
}

interface Snapshot {
  version: 1;
  chainId: number;
  /// Last block whose logs are fully contained in `events`. Inclusive.
  cursor: string;
  events: IndexedEvent[];
}

const eventKey = (e: IndexedEvent) => `${e.blockNumber}:${e.logIndex}`;

export class Store {
  private snapshot: Snapshot;
  private readonly path: string;
  private readonly seen: Set<string>;

  constructor(dataDir: string, chainId: number, startBlock: bigint) {
    mkdirSync(dataDir, { recursive: true });
    this.path = join(dataDir, `events-${chainId}.json`);

    if (existsSync(this.path)) {
      const parsed = JSON.parse(readFileSync(this.path, "utf8")) as Snapshot;
      if (parsed.chainId !== chainId) {
        throw new Error(`store at ${this.path} holds chain ${parsed.chainId}, expected ${chainId}`);
      }
      this.snapshot = parsed;
    } else {
      // The cursor is stored as "last block already indexed", so starting at `startBlock - 1`
      // means the first pass includes `startBlock` itself.
      this.snapshot = { version: 1, chainId, cursor: (startBlock - 1n).toString(), events: [] };
    }
    this.seen = new Set(this.snapshot.events.map(eventKey));
  }

  get cursor(): bigint {
    return BigInt(this.snapshot.cursor);
  }

  get events(): readonly IndexedEvent[] {
    return this.snapshot.events;
  }

  /// Insert events and advance the cursor in one atomic write. Returns how many were new.
  commit(events: IndexedEvent[], newCursor: bigint): number {
    let added = 0;
    for (const e of events) {
      const k = eventKey(e);
      if (this.seen.has(k)) continue; // idempotent replay
      this.seen.add(k);
      this.snapshot.events.push(e);
      added++;
    }
    if (added > 0) {
      this.snapshot.events.sort((a, b) => {
        const d = BigInt(a.blockNumber) - BigInt(b.blockNumber);
        if (d !== 0n) return d < 0n ? -1 : 1;
        return a.logIndex - b.logIndex;
      });
    }
    // Never move the cursor backwards: re-running with an older `--from` must not un-index work.
    if (newCursor > this.cursor) this.snapshot.cursor = newCursor.toString();
    this.flush();
    return added;
  }

  private flush(): void {
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.snapshot, null, 2));
    renameSync(tmp, this.path); // atomic
  }

  byName(name: string): IndexedEvent[] {
    return this.snapshot.events.filter((e) => e.name === name);
  }
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
