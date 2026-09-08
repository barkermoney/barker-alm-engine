import { parseAbi } from "viem";

/// Uniswap v4 `PoolManager`, the three events that describe a pool's whole life.
///
/// Written out by hand rather than imported from an artifact: the PoolManager deployed on Arc
/// tracks `v4-core` HEAD, and pinning the ABI here means a library bump cannot silently change
/// what this indexer believes an event looks like.
export const poolManagerEvents = parseAbi([
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
  "event ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)",
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
]);

export const poolManagerAbi = parseAbi([
  "function extsload(bytes32 slot) view returns (bytes32)",
  "function extsload(bytes32 startSlot, uint256 nSlots) view returns (bytes32[])",
]);

export const positionsEvents = parseAbi([
  "event PositionOpened(uint256 indexed positionId, bytes32 indexed poolId, address indexed owner, uint8 side, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amountFunded)",
  "event PositionClosed(uint256 indexed positionId, bytes32 indexed poolId, uint256 amount0Out, uint256 amount1Out)",
  "event FeesCollected(uint256 indexed positionId, bytes32 indexed poolId, uint256 amount0, uint256 amount1)",
  "event KeeperSet(address indexed keeper, bool allowed)",
  "event PausedSet(bool paused)",
]);

export const positionsAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct Position { PoolKey key; int24 tickLower; int24 tickUpper; uint128 liquidity; address owner; uint8 side; bool closed; }",
  "function getPosition(uint256 positionId) view returns (Position)",
  "function feesOwed(uint256 positionId) view returns (uint256 fee0, uint256 fee1)",
  "function nextPositionId() view returns (uint256)",
  "function isKeeper(address) view returns (bool)",
  "function paused() view returns (bool)",
  "function close(uint256 positionId) returns (uint256 amount0Out, uint256 amount1Out)",
  "function collect(uint256 positionId) returns (uint256 amount0, uint256 amount1)",
]);

export const hookEvents = parseAbi([
  "event FeeApplied(bytes32 indexed poolId, uint24 fee, uint24 surge, int24 tickMove)",
]);

export const erc20Abi = parseAbi([
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);
