import { encodeAbiParameters, keccak256, type Address, type Hex, type PublicClient } from "viem";
import { poolManagerAbi } from "./abi.js";

/// `pools` is slot 6 of the PoolManager. `Pool.State` then lays out:
///   +0 slot0 · +1 feeGrowthGlobal0X128 · +2 feeGrowthGlobal1X128 · +3 liquidity
const POOLS_SLOT = 6n;
const LIQUIDITY_OFFSET = 3n;

/// 🔴 The trap that costs an afternoon: `StateLibrary.getSlot0` is a **library** function, not a
/// method on the PoolManager. There is no `getSlot0()` in the deployed ABI, so an off-chain client
/// that reaches for the obvious call gets "function does not exist" and concludes the node is
/// broken. Reading v4 pool state off-chain means computing the storage slot yourself and going
/// through `extsload`. Every read below does that. See `FEEDBACK.md` §13.
export function poolStateSlot(poolId: Hex): Hex {
  return keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, POOLS_SLOT]),
  );
}

export interface Slot0 {
  sqrtPriceX96: bigint;
  tick: number;
  protocolFee: number;
  lpFee: number;
}

/// slot0 is one packed word:
///   [ 24 bits unused | 24 lpFee | 24 protocolFee | 24 tick | 160 sqrtPriceX96 ]
export function decodeSlot0(word: Hex): Slot0 {
  const raw = BigInt(word);
  const sqrtPriceX96 = raw & ((1n << 160n) - 1n);
  const tickBits = (raw >> 160n) & 0xffffffn;
  // int24, two's complement
  const tick = Number(tickBits >= 1n << 23n ? tickBits - (1n << 24n) : tickBits);
  const protocolFee = Number((raw >> 184n) & 0xffffffn);
  const lpFee = Number((raw >> 208n) & 0xffffffn);
  return { sqrtPriceX96, tick, protocolFee, lpFee };
}

export async function readSlot0(
  client: PublicClient,
  poolManager: Address,
  poolId: Hex,
): Promise<Slot0> {
  const word = await client.readContract({
    address: poolManager,
    abi: poolManagerAbi,
    functionName: "extsload",
    args: [poolStateSlot(poolId)],
  });
  return decodeSlot0(word as Hex);
}

export async function readPoolLiquidity(
  client: PublicClient,
  poolManager: Address,
  poolId: Hex,
): Promise<bigint> {
  const base = BigInt(poolStateSlot(poolId));
  const slot = `0x${(base + LIQUIDITY_OFFSET).toString(16).padStart(64, "0")}` as Hex;
  const word = await client.readContract({
    address: poolManager,
    abi: poolManagerAbi,
    functionName: "extsload",
    args: [slot],
  });
  return BigInt(word as Hex) & ((1n << 128n) - 1n);
}

/// Raw token1-per-token0 price at a tick, before decimals. `1.0001 ** tick` in float is accurate
/// enough for a display and a log line, and is not used for any decision the keeper makes —
/// decisions compare ticks to ticks, which are exact integers.
export function priceAtTick(tick: number): number {
  return Math.pow(1.0001, tick);
}

/// Human-readable price, adjusted for the two tokens' decimals.
export function displayPrice(tick: number, decimals0: number, decimals1: number): number {
  return priceAtTick(tick) * Math.pow(10, decimals0 - decimals1);
}

/// How far through its range a position has converted, as a fraction in [0, 1].
/// 0 = untouched, 1 = fully converted and ready to close.
export function conversionProgress(tick: number, tickLower: number, tickUpper: number, side: "Upper" | "Lower"): number {
  const span = tickUpper - tickLower;
  if (span <= 0) return 0;
  const clamped = Math.min(Math.max(tick, tickLower), tickUpper);
  const fromLower = (clamped - tickLower) / span;
  return side === "Upper" ? fromLower : 1 - fromLower;
}
