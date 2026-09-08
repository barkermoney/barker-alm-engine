import { strict as assert } from "node:assert";
import { test } from "node:test";
import { decide, isFullyConverted, nextConfirmations, type PolicyConfig, type PositionSnapshot } from "../src/policy.js";

const base: PositionSnapshot = {
  id: 1n,
  side: "Upper",
  tickLower: 600,
  tickUpper: 1200,
  liquidity: 10n ** 18n,
  owner: "0x0000000000000000000000000000000000000abc",
  closed: false,
  feesOwed0: 0n,
  feesOwed1: 0n,
};

const cfg: PolicyConfig = {
  confirmations: 3,
  minFeeSweepWei: 0n,
  paused: false,
  authorised: true,
  fundedForGas: true,
};

const at = (tick: number) => ({ tick, blockNumber: 1n });

test("an upper ladder is converted at or above its top tick, not before", () => {
  assert.equal(isFullyConverted(base, 1199), false);
  assert.equal(isFullyConverted(base, 1200), true);
  assert.equal(isFullyConverted(base, 1201), true);
});

test("a lower ladder is converted strictly below its bottom tick", () => {
  const lower = { ...base, side: "Lower" as const };
  // v4 ranges are active on [lower, upper), so sitting exactly at tickLower is still in range.
  assert.equal(isFullyConverted(lower, 600), false);
  assert.equal(isFullyConverted(lower, 599), true);
});

test("a working position is held", () => {
  const d = decide(base, at(900), cfg, 0);
  assert.equal(d.action, "hold");
});

test("conversion arms the keeper but does not fire until confirmations are met", () => {
  let confirmed = 0;
  for (let i = 0; i < cfg.confirmations - 1; i++) {
    const d = decide(base, at(1300), cfg, confirmed);
    assert.equal(d.action, "arm", `pass ${i} should arm, not act`);
    confirmed = nextConfirmations(confirmed, d);
  }
  const final = decide(base, at(1300), cfg, confirmed);
  assert.equal(final.action, "close");
});

test("a single-block wick out of the range resets the count", () => {
  let confirmed = 0;
  confirmed = nextConfirmations(confirmed, decide(base, at(1300), cfg, confirmed));
  assert.equal(confirmed, 1);
  // price comes straight back inside the range
  confirmed = nextConfirmations(confirmed, decide(base, at(900), cfg, confirmed));
  assert.equal(confirmed, 0, "one observation back in range must undo the countdown");
  // and the very next converted observation is only the first, not the second
  const d = decide(base, at(1300), cfg, confirmed);
  assert.equal(d.action, "arm");
  assert.match(d.reason, /1\/3/);
});

test("one confirmation configured means act on first sight", () => {
  const d = decide(base, at(1300), { ...cfg, confirmations: 1 }, 0);
  assert.equal(d.action, "close");
});

test("closed and empty positions are never acted on", () => {
  assert.equal(decide({ ...base, closed: true }, at(1300), cfg, 99).action, "hold");
  assert.equal(decide({ ...base, liquidity: 0n }, at(1300), cfg, 99).action, "hold");
});

test("an unauthorised or unfunded keeper holds instead of acting", () => {
  const unauth = decide(base, at(1300), { ...cfg, authorised: false }, 99);
  assert.equal(unauth.action, "hold");
  assert.match(unauth.reason, /not authorised/);

  const broke = decide(base, at(1300), { ...cfg, fundedForGas: false }, 99);
  assert.equal(broke.action, "hold");
  assert.match(broke.reason, /gas floor/);
});

test("fees are swept only once past the threshold, and never instead of an exit", () => {
  const withFees = { ...base, feesOwed0: 100n, feesOwed1: 50n };
  assert.equal(decide(withFees, at(900), { ...cfg, minFeeSweepWei: 200n }, 0).action, "hold");
  assert.equal(decide(withFees, at(900), { ...cfg, minFeeSweepWei: 150n }, 0).action, "collect");
  // conversion outranks a fee sweep: closing collects the fees anyway.
  assert.equal(decide(withFees, at(1300), { ...cfg, minFeeSweepWei: 1n }, 99).action, "close");
});

test("a zero threshold disables fee sweeping rather than sweeping constantly", () => {
  const withFees = { ...base, feesOwed0: 1n, feesOwed1: 0n };
  assert.equal(decide(withFees, at(900), { ...cfg, minFeeSweepWei: 0n }, 0).action, "hold");
});

test("the hold reason distinguishes not-yet-reached from being-filled", () => {
  // A `Lower` ladder above its range and an `Upper` ladder below it are both "working", but they
  // are working in opposite senses, and an operator reading the log needs to know which.
  assert.match(decide(base, at(400), cfg, 0).reason, /below \[600, 1200\)/);
  assert.match(decide(base, at(900), cfg, 0).reason, /inside \[600, 1200\)/);

  const lower = { ...base, side: "Lower" as const };
  assert.match(decide(lower, at(1500), cfg, 0).reason, /above \[600, 1200\)/);
});
