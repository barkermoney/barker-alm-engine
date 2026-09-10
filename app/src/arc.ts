import { createPublicClient, defineChain, http, type Address, type Hex, type PublicClient } from "viem";
import { erc20Abi, positionsAbi } from "../../keeper/src/abi";
import { compareEvents, eventKey, type EventLog, type IndexedEvent } from "../../keeper/src/events";
import { indexRange, summarisePositions, type PositionSummary } from "../../keeper/src/indexer";
import { conversionProgress, readSlot0 } from "../../keeper/src/poolState";

/// Pinned, like everything a judge has to be able to reproduce. See docs/environment.md.
export const ARC = {
  chainId: 5042002,
  rpc: "https://rpc.testnet.arc.io",
  explorer: "https://testnet.arcscan.app",
  poolManager: "0x2756F3F7bFAf103F4c550f4d24CdCa82B093240A" as Address,
  positions: "0x8ba4bFeC9616f2569AAB75AeC7B7411AA7F2a4Bb" as Address,
  /// Every hook we have deployed, oldest first. The Sep 4 hook's pool and its two lifecycles stay on
  /// chain; the Sep 10 hook carries the fee-decay fix (FEEDBACK.md §16). The last entry is current.
  hooks: [
    "0x31f6be09B9f63a26dfC894f9bBA7074047f59080",
    "0xFc50962B690B1d9eD1F7Af84c096892f027A5080",
  ] as Address[],
  startBlock: 60522409n,
} as const;

const arcTestnet = defineChain({
  id: ARC.chainId,
  name: "Arc Testnet",
  nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [ARC.rpc] } },
});

/// The keeper's `Store` keeps its log in a JSON file; this is the same log in memory, seeded from
/// that file and caught up live from its cursor. Same two rules: de-duplicate on
/// (block, logIndex), and move the cursor only together with the events it covers.
class MemoryLog implements EventLog {
  cursor: bigint;
  events: IndexedEvent[];
  private seen: Set<string>;

  constructor(cursor: bigint, events: IndexedEvent[]) {
    this.cursor = cursor;
    this.events = [...events].sort(compareEvents);
    this.seen = new Set(this.events.map(eventKey));
  }

  commit(batch: IndexedEvent[], newCursor: bigint): number {
    let added = 0;
    for (const e of batch) {
      const k = eventKey(e);
      if (this.seen.has(k)) continue;
      this.seen.add(k);
      this.events.push(e);
      added++;
    }
    if (added > 0) this.events.sort(compareEvents);
    if (newCursor > this.cursor) this.cursor = newCursor;
    return added;
  }
}

export interface Token {
  address: Address;
  symbol: string;
  decimals: number;
}

export interface PoolView {
  poolId: Hex;
  token0: Token;
  token1: Token;
  hooks: Address;
  swaps: number;
  /// Live, from slot0 via extsload. Undefined until the first read lands.
  tick?: number;
  lpFee?: number;
}

export type Status = "waiting" | "converting" | "converted" | "closed";

export interface PositionView {
  summary: PositionSummary;
  pool: PoolView;
  /// Pool tick immediately before the position was opened: the "spot" every percentage is against.
  tickAtOpen: number;
  /// Pool tick immediately before the close: where the ladder had got to when it was exited.
  tickAtClose?: number;
  status: Status;
  /// 0…1 through the range. For a closed position, how far it had converted when it was closed.
  progress: number;
  closedBy?: Address;
  closedByKeeper?: boolean;
  feesOwed?: readonly [bigint, bigint];
}

export interface FeeView {
  blockNumber: bigint;
  txHash: string;
  /// From the PoolManager's `Swap` event: the fee actually charged, override included.
  fee: number;
  /// From our hook's `FeeApplied`, matched by transaction: how that fee was arrived at.
  surge?: number;
  tickMove?: number;
}

export interface ArcState {
  head?: bigint;
  cursor: bigint;
  syncing: boolean;
  lastUpdate?: number;
  error?: string;
  pools: PoolView[];
  positions: PositionView[];
  keepers: Address[];
  fees: FeeView[];
}

const KNOWN_TOKENS: Record<string, Token> = {
  "0x3600000000000000000000000000000000000000": {
    address: "0x3600000000000000000000000000000000000000",
    symbol: "USDC",
    decimals: 6,
  },
};

export class ArcFeed {
  readonly client: PublicClient;
  private log = new MemoryLog(ARC.startBlock - 1n, []);
  private tokens = new Map<string, Token>();
  private live = new Map<string, { tick: number; lpFee: number }>();
  private senders = new Map<string, Address>();
  private fees = new Map<string, readonly [bigint, bigint]>();
  private head?: bigint;
  private syncing = false;
  private error?: string;
  private lastUpdate?: number;

  constructor(private onChange: (s: ArcState) => void) {
    this.client = createPublicClient({ chain: arcTestnet, transport: http(ARC.rpc, { retryCount: 2 }) }) as PublicClient;
  }

  /// Seed from the committed snapshot so the page is useful before a single RPC call returns.
  async seed(): Promise<void> {
    try {
      const res = await fetch(`${import.meta.env.BASE_URL}events-${ARC.chainId}.json`);
      if (res.ok) {
        const snap = (await res.json()) as { chainId: number; cursor: string; events: IndexedEvent[] };
        if (snap.chainId === ARC.chainId) this.log = new MemoryLog(BigInt(snap.cursor), snap.events);
      }
    } catch {
      // No snapshot is fine; the catch-up below will index from the registry's deployment block.
    }
    this.emit();
  }

  /// One pass: catch the log up to head, then read live pool state for the pools we care about.
  async refresh(): Promise<void> {
    try {
      const head = await this.client.getBlockNumber();
      this.head = head;
      if (head > this.log.cursor) {
        this.syncing = head - this.log.cursor > 2_000n;
        if (this.syncing) this.emit();
        await indexRange(
          this.client,
          this.log,
          { poolManager: ARC.poolManager, positions: ARC.positions, hook: ARC.hooks },
          head,
          20_000n,
          () => this.syncing && this.emit(),
        );
        this.syncing = false;
      }

      const positions = summarisePositions(this.log);
      const poolIds = [...new Set(positions.map((p) => p.poolId as Hex))];
      await Promise.all(poolIds.map((id) => this.readPool(id)));
      await Promise.all(positions.filter((p) => !p.closed).map((p) => this.readFees(p.positionId)));
      await Promise.all(positions.filter((p) => p.closeTx).map((p) => this.readSender(p.closeTx!)));

      this.error = undefined;
      this.lastUpdate = Date.now();
    } catch (err) {
      this.syncing = false;
      this.error = err instanceof Error ? err.message.split("\n")[0] : String(err);
    }
    this.emit();
  }

  private async readPool(poolId: Hex): Promise<void> {
    const init = this.log.events.find((e) => e.name === "Initialize" && e.args.id === poolId);
    if (init) {
      await Promise.all([this.token(String(init.args.currency0) as Address), this.token(String(init.args.currency1) as Address)]);
    }
    const s = await readSlot0(this.client, ARC.poolManager, poolId);
    this.live.set(poolId, { tick: s.tick, lpFee: s.lpFee });
  }

  private async readFees(positionId: string): Promise<void> {
    const fees = (await this.client.readContract({
      address: ARC.positions,
      abi: positionsAbi,
      functionName: "feesOwed",
      args: [BigInt(positionId)],
    })) as readonly [bigint, bigint];
    this.fees.set(positionId, fees);
  }

  private async readSender(txHash: string): Promise<void> {
    if (this.senders.has(txHash)) return;
    const tx = await this.client.getTransaction({ hash: txHash as Hex });
    this.senders.set(txHash, tx.from);
  }

  private async token(address: Address): Promise<void> {
    const key = address.toLowerCase();
    if (this.tokens.has(key)) return;
    const known = Object.entries(KNOWN_TOKENS).find(([k]) => k.toLowerCase() === key)?.[1];
    if (known) return void this.tokens.set(key, known);
    const [symbol, decimals] = await Promise.all([
      this.client.readContract({ address, abi: erc20Abi, functionName: "symbol" }),
      this.client.readContract({ address, abi: erc20Abi, functionName: "decimals" }),
    ]);
    this.tokens.set(key, { address, symbol: String(symbol), decimals: Number(decimals) });
  }

  private tokenOf(address: string): Token {
    return this.tokens.get(address.toLowerCase()) ?? { address: address as Address, symbol: short(address), decimals: 18 };
  }

  /// Last tick the pool is known to have had strictly before (block, logIndex).
  private tickBefore(poolId: string, block: string, logIndex: number): number | undefined {
    let tick: number | undefined;
    const b = BigInt(block);
    for (const e of this.log.events) {
      if (e.source !== "poolManager" || e.args.id !== poolId) continue;
      const eb = BigInt(e.blockNumber);
      if (eb > b || (eb === b && e.logIndex >= logIndex)) break;
      if (e.name === "Initialize" || e.name === "Swap") tick = Number(e.args.tick);
    }
    return tick;
  }

  private state(): ArcState {
    const summaries = summarisePositions(this.log);
    const poolViews = new Map<string, PoolView>();

    for (const id of new Set(summaries.map((p) => p.poolId))) {
      const init = this.log.events.find((e) => e.name === "Initialize" && e.args.id === id);
      const live = this.live.get(id);
      poolViews.set(id, {
        poolId: id as Hex,
        token0: this.tokenOf(String(init?.args.currency0 ?? "0x")),
        token1: this.tokenOf(String(init?.args.currency1 ?? "0x")),
        hooks: String(init?.args.hooks ?? ARC.hooks[ARC.hooks.length - 1]) as Address,
        swaps: this.log.events.filter((e) => e.name === "Swap" && e.args.id === id).length,
        tick: live?.tick,
        lpFee: live?.lpFee,
      });
    }

    const keepers = new Map<string, boolean>();
    for (const e of this.log.events) {
      if (e.source === "positions" && e.name === "KeeperSet") keepers.set(String(e.args.keeper), Boolean(e.args.allowed));
    }
    const keeperSet = new Set([...keepers].filter(([, on]) => on).map(([k]) => k.toLowerCase()));

    const positions: PositionView[] = summaries.map((s) => {
      const pool = poolViews.get(s.poolId)!;
      const openEvent = this.log.events.find((e) => e.name === "PositionOpened" && String(e.args.positionId) === s.positionId);
      const closeEvent = this.log.events.find((e) => e.name === "PositionClosed" && String(e.args.positionId) === s.positionId);
      const tickAtOpen = openEvent ? this.tickBefore(s.poolId, openEvent.blockNumber, openEvent.logIndex) ?? s.tickLower : s.tickLower;
      const tickAtClose = closeEvent ? this.tickBefore(s.poolId, closeEvent.blockNumber, closeEvent.logIndex) : undefined;

      const at = s.closed ? tickAtClose : pool.tick;
      const progress = at === undefined ? 0 : conversionProgress(at, s.tickLower, s.tickUpper, s.side);

      let status: Status = "closed";
      if (!s.closed) status = progress >= 1 ? "converted" : progress > 0 ? "converting" : "waiting";

      const closedBy = s.closeTx ? this.senders.get(s.closeTx) : undefined;
      return {
        summary: s,
        pool,
        tickAtOpen,
        tickAtClose,
        status,
        progress,
        closedBy,
        closedByKeeper: closedBy ? keeperSet.has(closedBy.toLowerCase()) : undefined,
        feesOwed: this.fees.get(s.positionId),
      };
    });

    // Every swap on our pools, priced by the PoolManager's own event. v4 puts the applied fee —
    // the hook's override when there is one — in `Swap.fee`; our `FeeApplied` only adds why.
    const breakdown = new Map(
      this.log.events.filter((e) => e.source === "hook" && e.name === "FeeApplied").map((e) => [`${e.txHash}:${e.args.poolId}`, e]),
    );
    const fees: FeeView[] = this.log.events
      .filter((e) => e.source === "poolManager" && e.name === "Swap" && poolViews.has(String(e.args.id)))
      .map((e) => {
        const why = breakdown.get(`${e.txHash}:${e.args.id}`);
        return {
          blockNumber: BigInt(e.blockNumber),
          txHash: e.txHash,
          fee: Number(e.args.fee),
          surge: why ? Number(why.args.surge) : undefined,
          tickMove: why ? Number(why.args.tickMove) : undefined,
        };
      });

    return {
      head: this.head,
      cursor: this.log.cursor,
      syncing: this.syncing,
      lastUpdate: this.lastUpdate,
      error: this.error,
      pools: [...poolViews.values()],
      positions: positions.reverse(), // newest first
      keepers: [...keeperSet] as Address[],
      fees: fees.reverse(),
    };
  }

  private emit(): void {
    this.onChange(this.state());
  }
}

export function short(a: string): string {
  return a.length > 12 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a;
}
