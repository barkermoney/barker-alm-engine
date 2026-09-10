import { createPublicClient, fallback, http, parseAbi, type Address, type PublicClient } from "viem";
import { mainnet } from "viem/chains";

export const STEAK_USDC: Address = "0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB";

/// Public mainnet endpoints that answer browser CORS and serve historical `eth_call`, verified
/// Sep 10. publicnode stopped serving the latter without a token that day, which is why it is last.
const MAINNET_RPCS = [
  "https://eth.drpc.org",
  "https://eth-mainnet.public.blastapi.io",
  "https://ethereum-rpc.publicnode.com",
];

const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
]);

export interface VaultState {
  block?: bigint;
  totalAssets?: bigint; // USDC, 6 dp
  sharePrice?: number; // USDC per share
  /// Annualised from the share price seven days ago. Undefined if no endpoint would serve the
  /// historical read — shown as unavailable rather than guessed.
  apy?: number;
  error?: string;
}

/// One step of the recorded mainnet-fork run. Written by `aqua/test/YieldBackedSettlementMainnetFork.t.sol`,
/// `test_recordDashboardTrace`; every figure is a balance read on the fork at that step.
export interface TraceStep {
  id: "deposit" | "quote" | "fill-out" | "fill-in" | "accrue";
  text: string;
  block: number;
  timestamp: number;
  amountIn: string;
  amountOut: string;
  makerWalletUsdc: string;
  makerWalletUsdt: string;
  makerVaultUsdc: string;
  makerShares: string;
}

export interface Trace {
  recordedAtBlock: number;
  vault: Address;
  virtualReserve: string;
  backing: string;
  unguardedQuote: string;
  guardedQuote: string;
  steps: TraceStep[];
}

const SHARE = 10n ** 18n; // steakUSDC shares have 18 decimals over a 6-decimal asset
const WEEK_BLOCKS = 50_400n; // ~7 days at 12s

export class AquaFeed {
  private client: PublicClient;
  private state: VaultState = {};

  constructor(private onChange: (s: VaultState) => void) {
    this.client = createPublicClient({
      chain: mainnet,
      transport: fallback(MAINNET_RPCS.map((u) => http(u, { retryCount: 1, timeout: 12_000 }))),
    }) as PublicClient;
  }

  async refresh(): Promise<void> {
    try {
      const block = await this.client.getBlockNumber();
      const [totalAssets, assetsPerShare] = await Promise.all([
        this.client.readContract({ address: STEAK_USDC, abi: vaultAbi, functionName: "totalAssets", blockNumber: block }),
        this.client.readContract({ address: STEAK_USDC, abi: vaultAbi, functionName: "convertToAssets", args: [SHARE], blockNumber: block }),
      ]);
      this.state = {
        ...this.state,
        block,
        totalAssets,
        sharePrice: Number(assetsPerShare) / 1e6,
        error: undefined,
      };
      this.onChange(this.state);

      if (this.state.apy === undefined) this.state.apy = await this.weeklyApy(block, assetsPerShare);
    } catch (err) {
      this.state = { ...this.state, error: err instanceof Error ? err.message.split("\n")[0] : String(err) };
    }
    this.onChange(this.state);
  }

  private async weeklyApy(block: bigint, nowAssets: bigint): Promise<number | undefined> {
    try {
      const then = block - WEEK_BLOCKS;
      const [thenAssets, nowBlock, thenBlock] = await Promise.all([
        this.client.readContract({ address: STEAK_USDC, abi: vaultAbi, functionName: "convertToAssets", args: [SHARE], blockNumber: then }),
        this.client.getBlock({ blockNumber: block }),
        this.client.getBlock({ blockNumber: then }),
      ]);
      const growth = Number(nowAssets) / Number(thenAssets);
      const years = Number(nowBlock.timestamp - thenBlock.timestamp) / (365 * 86_400);
      return Math.pow(growth, 1 / years) - 1;
    } catch {
      return undefined;
    }
  }
}

export async function loadTrace(): Promise<Trace | undefined> {
  try {
    const res = await fetch(`${import.meta.env.BASE_URL}aqua-fork-trace.json`);
    return res.ok ? ((await res.json()) as Trace) : undefined;
  } catch {
    return undefined;
  }
}
