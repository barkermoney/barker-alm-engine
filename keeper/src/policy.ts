/// The keeper's decision function. Deliberately pure: no clients, no clock, no I/O.
///
/// Everything the keeper does to a position on chain is decided here, from a snapshot, so the
/// interesting behaviour can be tested without a node — and so that the rule a reviewer reads is
/// literally the rule that runs. A policy that lives smeared across a polling loop is a policy
/// nobody can check.

export type Side = "Upper" | "Lower";

export interface PositionSnapshot {
  id: bigint;
  side: Side;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  owner: `0x${string}`;
  closed: boolean;
  feesOwed0: bigint;
  feesOwed1: bigint;
}

export interface MarketSnapshot {
  tick: number;
  blockNumber: bigint;
}

export interface PolicyConfig {
  /// Consecutive observations the exit condition must survive before the keeper acts.
  confirmations: number;
  /// Don't spend a transaction sweeping dust.
  minFeeSweepWei: bigint;
  /// Paused registry: opening is blocked, but closing must still be possible.
  paused: boolean;
  /// The keeper is authorised on the registry.
  authorised: boolean;
  /// The keeper can pay for gas.
  fundedForGas: boolean;
}

export type Decision =
  | { action: "close"; reason: string }
  | { action: "collect"; reason: string }
  | { action: "hold"; reason: string }
  | { action: "arm"; reason: string };

/// Tracks how many consecutive observations have satisfied the exit condition, per position.
/// Held by the caller so a restart starts the count over — deliberately: a keeper that comes back
/// from a crash should re-observe the market before acting on it, not trust a stale count.
export type ConfirmationState = Map<string, number>;

/// Has the ladder finished converting?
///
/// An `Upper` position — a take-profit ladder funded in the base asset — is fully converted once
/// price is at or above `tickUpper`: every unit of liquidity has been sold and the position is
/// 100% quote asset. Below `tickUpper` it is still working, and closing early would leave the
/// unconverted remainder to be sold at market instead of at the ladder's prices.
///
/// `Lower` is the mirror: a bid ladder is done accumulating once price is strictly below
/// `tickLower`. The asymmetry in the comparisons is v4's, not ours — a range is active while
/// `tickLower <= tick < tickUpper`, so "at tickUpper" is already out of range on the upside while
/// "at tickLower" is still in range on the downside.
export function isFullyConverted(p: PositionSnapshot, tick: number): boolean {
  return p.side === "Upper" ? tick >= p.tickUpper : tick < p.tickLower;
}

export function decide(
  p: PositionSnapshot,
  m: MarketSnapshot,
  cfg: PolicyConfig,
  confirmed: number,
): Decision {
  if (p.closed) return { action: "hold", reason: "already closed" };
  if (p.liquidity === 0n) return { action: "hold", reason: "no liquidity on chain" };

  if (isFullyConverted(p, m.tick)) {
    // Gate the *action*, never the observation. A keeper that stops watching because it cannot
    // currently transact is a keeper that misses the exit and then reports everything as fine.
    if (!cfg.authorised) return { action: "hold", reason: "converted, but keeper is not authorised on the registry" };
    if (!cfg.fundedForGas) return { action: "hold", reason: "converted, but keeper is below its gas floor" };

    if (confirmed + 1 < cfg.confirmations) {
      return {
        action: "arm",
        reason: `converted at tick ${m.tick} (${confirmed + 1}/${cfg.confirmations} confirmations)`,
      };
    }
    return {
      action: "close",
      reason: `fully converted: tick ${m.tick} ${p.side === "Upper" ? ">=" : "<"} ${p.side === "Upper" ? p.tickUpper : p.tickLower}, held for ${cfg.confirmations} observations`,
    };
  }

  const fees = p.feesOwed0 + p.feesOwed1;
  if (fees >= cfg.minFeeSweepWei && cfg.minFeeSweepWei > 0n) {
    if (!cfg.authorised) return { action: "hold", reason: "fees above threshold, but keeper is not authorised" };
    if (!cfg.fundedForGas) return { action: "hold", reason: "fees above threshold, but keeper is below its gas floor" };
    return { action: "collect", reason: `uncollected fees ${fees} >= ${cfg.minFeeSweepWei}` };
  }

  // "Working" covers two genuinely different states and the log should say which: a ladder the
  // price has not reached yet, and one it is currently being filled through. Calling both "inside
  // the range" makes the log lie about the second-most important fact on the line.
  const where = m.tick < p.tickLower ? "below" : m.tick >= p.tickUpper ? "above" : "inside";
  return {
    action: "hold",
    reason: `still working: tick ${m.tick}, ${where} [${p.tickLower}, ${p.tickUpper})`,
  };
}

/// Fold a decision back into the confirmation counter. `arm` increments, anything else resets —
/// so the counter measures *consecutive* observations, and a single block back inside the range
/// puts the position back to square one.
export function nextConfirmations(previous: number, d: Decision): number {
  return d.action === "arm" ? previous + 1 : d.action === "close" ? 0 : 0;
}
