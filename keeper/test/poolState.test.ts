import { strict as assert } from "node:assert";
import { test } from "node:test";
import { conversionProgress, decodeSlot0, poolStateSlot } from "../src/poolState.js";

/// Captured live from the Arc testnet PoolManager on Sep 8, 2026 for the BPROBE/USDC pool.
/// `lpFee` reading back as 3000 is the hook's `afterInitialize` having done its job, and it is
/// what makes this a real fixture rather than a restatement of the decoder.
const LIVE_SLOT0 = "0x000000000bb8000000fa64ec00000000000000000000002d44ee1487de2ec770" as const;

test("slot0 decodes the packed word the way v4 packs it", () => {
  const s = decodeSlot0(LIVE_SLOT0);
  assert.equal(s.lpFee, 3000, "dynamic fee set by the hook at afterInitialize");
  assert.equal(s.protocolFee, 0);
  // -367380 is exactly where the Sep 4 lifecycle swap stopped, at its limit tick — so this
  // fixture also cross-checks the decoder against `arc/DEPLOYMENTS.md`, independently recorded.
  assert.equal(s.tick, -367380, "int24 must sign-extend, not read as a huge positive");
  assert.equal(s.sqrtPriceX96, 0x00000000000000000000002d44ee1487de2ec770n);
});

test("a positive tick decodes without borrowing the sign bit", () => {
  // tick = 1200 = 0x0004b0, lpFee 500, protocolFee 0, sqrtPrice 1
  const word = ("0x" + "0000000001f4" + "000000" + "0004b0" + "1".padStart(40, "0")) as `0x${string}`;
  const s = decodeSlot0(word);
  assert.equal(s.tick, 1200);
  assert.equal(s.lpFee, 500);
  assert.equal(s.sqrtPriceX96, 1n);
});

test("the pool state slot is the mapping slot, not the pool id", () => {
  // Verified against `cast keccak $(cast concat-hex $POOL_ID 0x..06)` on Arc.
  const poolId = "0x3169c2477f74cfacfc7db206cd19628d3a6eb1b4d541afee840fc12e0fc1da60";
  assert.equal(
    poolStateSlot(poolId),
    "0xf3373e00b4b5175a821cd924695cbe6b1681666f68e17878f465fa628f8edb09",
  );
});

test("conversion progress runs 0 → 1 in the direction the ladder sells", () => {
  assert.equal(conversionProgress(600, 600, 1200, "Upper"), 0);
  assert.equal(conversionProgress(900, 600, 1200, "Upper"), 0.5);
  assert.equal(conversionProgress(1200, 600, 1200, "Upper"), 1);
  assert.equal(conversionProgress(5000, 600, 1200, "Upper"), 1, "clamped above the range");

  assert.equal(conversionProgress(1200, 600, 1200, "Lower"), 0);
  assert.equal(conversionProgress(600, 600, 1200, "Lower"), 1);
  assert.equal(conversionProgress(-5000, 600, 1200, "Lower"), 1, "clamped below the range");
});
