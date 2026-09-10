import type { Address, PublicClient } from "viem";
import { hookEvents, poolManagerEvents, positionsEvents } from "./abi.js";
import { serialiseArgs, type EventLog, type IndexedEvent } from "./events.js";

export interface IndexTargets {
  poolManager: Address;
  positions: Address;
  hook?: Address;
}

/// Pull every log the system produces, in pages, into the store.
///
/// The v4 side is the interesting half: `Initialize`, `ModifyLiquidity` and `Swap` on the
/// PoolManager are the *only* record of what happened to a pool, because v4 keeps pools in a
/// singleton's transient-accounted storage rather than in one contract per pair. There is no pool
/// contract to query and no `Sync` event to lean on — reconstructing a pool's history means these
/// three events plus `extsload`. That is a real change in how you write an indexer for v4 versus
/// v3, and it is the thing most likely to bite someone porting one over.
export async function indexRange(
  client: PublicClient,
  store: EventLog,
  targets: IndexTargets,
  toBlock: bigint,
  pageSize: bigint,
  onPage?: (from: bigint, to: bigint, found: number) => void,
): Promise<number> {
  let total = 0;
  let from = store.cursor + 1n;
  let page = pageSize;

  while (from <= toBlock) {
    const to = from + page - 1n > toBlock ? toBlock : from + page - 1n;

    let pmLogs, posLogs, hookLogs;
    try {
      [pmLogs, posLogs, hookLogs] = await Promise.all([
        client.getLogs({ address: targets.poolManager, events: poolManagerEvents, fromBlock: from, toBlock: to }),
        client.getLogs({ address: targets.positions, events: positionsEvents, fromBlock: from, toBlock: to }),
        targets.hook
          ? client.getLogs({ address: targets.hook, events: hookEvents, fromBlock: from, toBlock: to })
          : Promise.resolve([]),
      ]);
    } catch (err) {
      // Arc's public node caps `eth_getLogs` at somewhere between 25k and 30k blocks and says so
      // with code -32012. Rather than hard-coding a number that a node operator is free to change
      // tomorrow, halve and retry. Note that `cast logs` paginates internally and never surfaces
      // this, so the limit is invisible until you write a client of your own — see FEEDBACK §15.
      if (isRangeTooLarge(err) && page > MIN_PAGE) {
        page = page / 2n > MIN_PAGE ? page / 2n : MIN_PAGE;
        continue;
      }
      throw err;
    }

    const batch: IndexedEvent[] = [
      ...pmLogs.map((l) => toIndexed(l, "poolManager")),
      ...posLogs.map((l) => toIndexed(l, "positions")),
      ...hookLogs.map((l) => toIndexed(l, "hook")),
    ];

    // Data and cursor move together, or neither moves.
    const added = store.commit(batch, to);
    total += added;
    onPage?.(from, to, added);

    from = to + 1n;
  }

  return total;
}

const MIN_PAGE = 500n;

function isRangeTooLarge(err: unknown): boolean {
  const text = err instanceof Error ? `${err.message} ${(err as any).details ?? ""}` : String(err);
  return /range too large|-32012|exceed|too many results|limit exceeded/i.test(text);
}

function toIndexed(log: any, source: IndexedEvent["source"]): IndexedEvent {
  return {
    blockNumber: (log.blockNumber as bigint).toString(),
    logIndex: log.logIndex as number,
    txHash: log.transactionHash as string,
    source,
    name: log.eventName as string,
    args: serialiseArgs((log.args ?? {}) as Record<string, unknown>),
  };
}

/// Everything the dashboard needs about one pool, folded out of the event log.
export interface PoolSummary {
  poolId: string;
  currency0?: string;
  currency1?: string;
  fee?: string;
  tickSpacing?: string;
  hooks?: string;
  initializedAtBlock?: string;
  swaps: number;
  liquidityEvents: number;
  lastTick?: number;
}

export function summarisePools(store: Pick<EventLog, "events">): PoolSummary[] {
  const pools = new Map<string, PoolSummary>();

  const get = (id: string): PoolSummary => {
    let p = pools.get(id);
    if (!p) {
      p = { poolId: id, swaps: 0, liquidityEvents: 0 };
      pools.set(id, p);
    }
    return p;
  };

  for (const e of store.events) {
    if (e.source !== "poolManager") continue;
    const id = String(e.args.id);
    const p = get(id);
    if (e.name === "Initialize") {
      p.currency0 = String(e.args.currency0);
      p.currency1 = String(e.args.currency1);
      p.fee = String(e.args.fee);
      p.tickSpacing = String(e.args.tickSpacing);
      p.hooks = String(e.args.hooks);
      p.initializedAtBlock = e.blockNumber;
      p.lastTick = Number(e.args.tick);
    } else if (e.name === "Swap") {
      p.swaps++;
      p.lastTick = Number(e.args.tick);
    } else if (e.name === "ModifyLiquidity") {
      p.liquidityEvents++;
    }
  }

  return [...pools.values()];
}

export interface PositionSummary {
  positionId: string;
  poolId: string;
  owner: string;
  side: "Upper" | "Lower";
  tickLower: number;
  tickUpper: number;
  liquidity: string;
  amountFunded: string;
  openedAtBlock: string;
  openTx: string;
  closed: boolean;
  closedAtBlock?: string;
  closeTx?: string;
  amount0Out?: string;
  amount1Out?: string;
  collected0: bigint;
  collected1: bigint;
}

/// The position registry, rebuilt from events alone. This is what makes the dashboard cheap: it
/// never walks the registry mapping, it replays the log.
export function summarisePositions(store: Pick<EventLog, "events">): PositionSummary[] {
  const byId = new Map<string, PositionSummary>();

  for (const e of store.events) {
    if (e.source !== "positions") continue;
    const id = String(e.args.positionId);

    if (e.name === "PositionOpened") {
      byId.set(id, {
        positionId: id,
        poolId: String(e.args.poolId),
        owner: String(e.args.owner),
        side: Number(e.args.side) === 0 ? "Upper" : "Lower",
        tickLower: Number(e.args.tickLower),
        tickUpper: Number(e.args.tickUpper),
        liquidity: String(e.args.liquidity),
        amountFunded: String(e.args.amountFunded),
        openedAtBlock: e.blockNumber,
        openTx: e.txHash,
        closed: false,
        collected0: 0n,
        collected1: 0n,
      });
    } else if (e.name === "PositionClosed") {
      const p = byId.get(id);
      if (!p) continue;
      p.closed = true;
      p.closedAtBlock = e.blockNumber;
      p.closeTx = e.txHash;
      p.amount0Out = String(e.args.amount0Out);
      p.amount1Out = String(e.args.amount1Out);
    } else if (e.name === "FeesCollected") {
      const p = byId.get(id);
      if (!p) continue;
      p.collected0 += BigInt(String(e.args.amount0));
      p.collected1 += BigInt(String(e.args.amount1));
    }
  }

  return [...byId.values()].sort((a, b) => Number(BigInt(a.positionId) - BigInt(b.positionId)));
}
