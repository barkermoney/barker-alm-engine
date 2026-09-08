import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  keccak256,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { positionsAbi } from "./abi.js";
import { config, keeperPrivateKey } from "./config.js";
import { readSlot0 } from "./poolState.js";
import {
  decide,
  nextConfirmations,
  type ConfirmationState,
  type Decision,
  type PositionSnapshot,
} from "./policy.js";

export function publicClient(): PublicClient {
  return createPublicClient({ chain: config.chain, transport: http() }) as PublicClient;
}

export function walletClient(): { client: WalletClient; account: ReturnType<typeof privateKeyToAccount> } {
  const account = privateKeyToAccount(keeperPrivateKey());
  const client = createWalletClient({ account, chain: config.chain, transport: http() });
  return { client, account };
}

export interface PoolKeyStruct {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

/// v4's `PoolId` is `keccak256(abi.encode(poolKey))` — the five fields, one word each. There is no
/// registry mapping id back to key, which is why an indexer has to keep `Initialize` around.
export function toPoolId(key: PoolKeyStruct): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "uint24" },
        { type: "int24" },
        { type: "address" },
      ],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
    ),
  );
}

export interface LoadedPosition {
  snapshot: PositionSnapshot;
  poolId: Hex;
  key: PoolKeyStruct;
}

/// Read the whole registry straight from chain. The registry is small and ids are dense, so this
/// stays honest and simple; the event-sourced view in `indexer.ts` is what scales, and the two
/// exist side by side on purpose — if they ever disagree, that disagreement is the bug report.
export async function loadPositions(client: PublicClient): Promise<LoadedPosition[]> {
  const next = await client.readContract({
    address: config.positions,
    abi: positionsAbi,
    functionName: "nextPositionId",
  });

  const out: LoadedPosition[] = [];
  for (let id = 1n; id < (next as bigint); id++) {
    const p = (await client.readContract({
      address: config.positions,
      abi: positionsAbi,
      functionName: "getPosition",
      args: [id],
    })) as any;

    let feesOwed0 = 0n;
    let feesOwed1 = 0n;
    if (!p.closed) {
      const fees = (await client.readContract({
        address: config.positions,
        abi: positionsAbi,
        functionName: "feesOwed",
        args: [id],
      })) as readonly [bigint, bigint];
      feesOwed0 = fees[0];
      feesOwed1 = fees[1];
    }

    const key: PoolKeyStruct = {
      currency0: p.key.currency0,
      currency1: p.key.currency1,
      fee: Number(p.key.fee),
      tickSpacing: Number(p.key.tickSpacing),
      hooks: p.key.hooks,
    };

    out.push({
      key,
      poolId: toPoolId(key),
      snapshot: {
        id,
        side: Number(p.side) === 0 ? "Upper" : "Lower",
        tickLower: Number(p.tickLower),
        tickUpper: Number(p.tickUpper),
        liquidity: BigInt(p.liquidity),
        owner: p.owner,
        closed: Boolean(p.closed),
        feesOwed0,
        feesOwed1,
      },
    });
  }
  return out;
}

export interface TickResult {
  position: LoadedPosition;
  decision: Decision;
  txHash?: Hex;
  error?: string;
}

/// One pass over every position. Read state, decide, and act on whatever the policy authorised.
export async function tick(
  client: PublicClient,
  wallet: { client: WalletClient; account: ReturnType<typeof privateKeyToAccount> } | undefined,
  confirmations: ConfirmationState,
): Promise<TickResult[]> {
  const blockNumber = await client.getBlockNumber();
  const positions = await loadPositions(client);

  const paused = (await client.readContract({
    address: config.positions,
    abi: positionsAbi,
    functionName: "paused",
  })) as boolean;

  let authorised = false;
  let fundedForGas = false;
  if (wallet) {
    authorised = (await client.readContract({
      address: config.positions,
      abi: positionsAbi,
      functionName: "isKeeper",
      args: [wallet.account.address],
    })) as boolean;
    const balance = await client.getBalance({ address: wallet.account.address });
    fundedForGas = balance >= config.minGasBalanceWei;
  }

  const results: TickResult[] = [];
  const tickCache = new Map<string, number>();

  for (const p of positions) {
    if (p.snapshot.closed) continue;

    let poolTick = tickCache.get(p.poolId);
    if (poolTick === undefined) {
      poolTick = (await readSlot0(client, config.poolManager, p.poolId)).tick;
      tickCache.set(p.poolId, poolTick);
    }

    const key = p.snapshot.id.toString();
    const seen = confirmations.get(key) ?? 0;
    const decision = decide(
      p.snapshot,
      { tick: poolTick, blockNumber },
      {
        confirmations: config.confirmations,
        minFeeSweepWei: config.minFeeSweepWei,
        paused,
        authorised,
        fundedForGas,
      },
      seen,
    );
    confirmations.set(key, nextConfirmations(seen, decision));

    const result: TickResult = { position: p, decision };

    if ((decision.action === "close" || decision.action === "collect") && wallet) {
      try {
        // No simulation before sending. On Arc, a call that touches USDC reverts inside a
        // simulated EVM that does not implement the precompile, so simulate-then-send would
        // refuse to broadcast transactions that succeed perfectly well on a real node.
        result.txHash = await wallet.client.writeContract({
          address: config.positions,
          abi: positionsAbi,
          functionName: decision.action,
          args: [p.snapshot.id],
          account: wallet.account,
          chain: config.chain,
        });
        await client.waitForTransactionReceipt({ hash: result.txHash });
      } catch (err) {
        result.error = err instanceof Error ? err.message.split("\n")[0] : String(err);
        // A failed send must not be mistaken for a satisfied exit: put the position back to
        // fully armed so the next pass retries immediately rather than re-serving the countdown.
        confirmations.set(key, config.confirmations - 1);
      }
    }

    results.push(result);
  }

  return results;
}
