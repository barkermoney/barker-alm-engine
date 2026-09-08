import { config } from "./config.js";
import { indexRange, summarisePools, summarisePositions } from "./indexer.js";
import { conversionProgress, readSlot0 } from "./poolState.js";
import { Store } from "./store.js";
import { loadPositions, publicClient, tick, walletClient } from "./keeper.js";
import type { ConfirmationState } from "./policy.js";

const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);

async function cmdIndex(): Promise<void> {
  const client = publicClient();
  const store = new Store(config.dataDir, config.chain.id, config.startBlock);
  const head = await client.getBlockNumber();
  log(`indexing ${store.cursor + 1n} → ${head}`);

  const added = await indexRange(
    client,
    store,
    { poolManager: config.poolManager, positions: config.positions, hook: config.hook },
    head,
    config.logPageSize,
    (from, to, found) => found > 0 && log(`  [${from}, ${to}] +${found}`),
  );

  log(`${added} new events, ${store.events.length} total, cursor at ${store.cursor}`);
  for (const p of summarisePools(store)) {
    log(`pool ${p.poolId.slice(0, 10)}… fee=${p.fee} spacing=${p.tickSpacing} swaps=${p.swaps} liq-events=${p.liquidityEvents} lastTick=${p.lastTick}`);
  }
  for (const p of summarisePositions(store)) {
    log(`position #${p.positionId} ${p.side} [${p.tickLower}, ${p.tickUpper}) ${p.closed ? `closed → ${p.amount0Out}/${p.amount1Out}` : "open"}`);
  }
}

async function cmdStatus(): Promise<void> {
  const client = publicClient();
  const positions = await loadPositions(client);
  const head = await client.getBlockNumber();
  log(`block ${head} · registry ${config.positions}`);

  if (positions.length === 0) return void log("no positions yet");

  for (const p of positions) {
    if (p.snapshot.closed) {
      log(`#${p.snapshot.id} ${p.snapshot.side} [${p.snapshot.tickLower}, ${p.snapshot.tickUpper}) closed`);
      continue;
    }
    const slot0 = await readSlot0(client, config.poolManager, p.poolId);
    const pct = (conversionProgress(slot0.tick, p.snapshot.tickLower, p.snapshot.tickUpper, p.snapshot.side) * 100).toFixed(1);
    log(
      `#${p.snapshot.id} ${p.snapshot.side} [${p.snapshot.tickLower}, ${p.snapshot.tickUpper}) ` +
        `tick=${slot0.tick} converted=${pct}% lpFee=${slot0.lpFee} fees=${p.snapshot.feesOwed0}/${p.snapshot.feesOwed1} owner=${p.snapshot.owner}`,
    );
  }
}

async function runTick(confirmations: ConfirmationState, dry: boolean): Promise<void> {
  const client = publicClient();
  const wallet = dry ? undefined : walletClient();
  if (wallet) log(`keeper ${wallet.account.address}`);

  const results = await tick(client, wallet, confirmations);
  for (const r of results) {
    const line = `#${r.position.snapshot.id} ${r.decision.action.toUpperCase()} — ${r.decision.reason}`;
    if (r.error) log(`${line} · FAILED: ${r.error}`);
    else if (r.txHash) log(`${line} · tx ${r.txHash}`);
    else log(line);
  }
  if (results.length === 0) log("no open positions");
}

async function cmdOnce(): Promise<void> {
  await runTick(new Map(), process.env.KEEPER_PRIVATE_KEY === undefined);
}

/// The unattended loop. Nothing here asks a human anything: it polls, decides, and acts.
async function cmdRun(): Promise<void> {
  const confirmations: ConfirmationState = new Map();
  let stopping = false;
  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      log(`${sig} — finishing this pass then stopping`);
      stopping = true;
    });
  }

  log(`keeper starting · poll ${config.pollMs}ms · ${config.confirmations} confirmations required`);
  while (!stopping) {
    try {
      await runTick(confirmations, false);
    } catch (err) {
      // A keeper that dies on a transient RPC error is a keeper that was never unattended.
      log(`pass failed, continuing: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`);
    }
    if (stopping) break;
    await new Promise((r) => setTimeout(r, config.pollMs));
  }
  log("stopped");
}

const commands: Record<string, () => Promise<void>> = {
  index: cmdIndex,
  status: cmdStatus,
  once: cmdOnce,
  run: cmdRun,
};

const name = process.argv[2] ?? "status";
const cmd = commands[name];
if (!cmd) {
  console.error(`unknown command "${name}". one of: ${Object.keys(commands).join(", ")}`);
  process.exit(1);
}
cmd().catch((err) => {
  console.error(err);
  process.exit(1);
});
