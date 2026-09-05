#!/usr/bin/env python3
"""V4 单边仓探针参数计算(高精度整数/Decimal)
定价:1 ProbeToken(18d) = 1e-4 USDC(6d) → raw price(token1/token0) = 1e-16
currency0 = ProbeToken 0x18B1...(地址小), currency1 = USDC 壳 0x3600...
"""
from decimal import Decimal, getcontext

getcontext().prec = 60
Q96 = 2**96


def tick_to_sqrtX96(tick: int) -> int:
    return int(Decimal(1.0001) ** (Decimal(tick) / 2) * Q96)


def price_to_tick(price: Decimal) -> Decimal:
    return price.ln() / Decimal("1.0001").ln()


# --- 建池价 ---
raw_price = Decimal("1e-16")
sqrtP_init = int(raw_price.sqrt() * Q96)
tick_now = price_to_tick(raw_price)
print(f"init sqrtPriceX96 = {sqrtP_init}")
print(f"预期现价 tick     = {tick_now:.1f}")

# --- 止盈腿区间(tickSpacing 60) ---
TL, TU = -367920, -367320
assert TL % 60 == 0 and TU % 60 == 0
gain_lo = Decimal("1.0001") ** (TL - int(tick_now)) - 1
gain_hi = Decimal("1.0001") ** (TU - int(tick_now)) - 1
print(f"区间 [{TL}, {TU}] = 现价上方 +{gain_lo*100:.2f}% ~ +{gain_hi*100:.2f}%")

sqrtA = tick_to_sqrtX96(TL)
sqrtB = tick_to_sqrtX96(TU)
print(f"sqrtA(X96) = {sqrtA}")
print(f"sqrtB(X96) = {sqrtB}")

# --- L:目标 amount0 = 2 万 PT(getLiquidityForAmount0) ---
amount0 = 2 * 10**22
L = amount0 * sqrtA * sqrtB // (Q96 * (sqrtB - sqrtA))
print(f"amount0 目标 = {amount0} (2万 PT)")
print(f"liquidity L  = {L}")

# 校验:链上会按 L 精确反算 amount0(ceil)
need0 = (L * Q96 * (sqrtB - sqrtA) + (sqrtA * sqrtB - 1)) // (sqrtA * sqrtB)
print(f"反算 amount0 ≈ {need0} ({Decimal(need0)/10**18:.2f} PT)")

# --- 穿越区间所需 USDC(amount1 = L*(sqrtB-sqrtA)/Q96) ---
need1 = L * (sqrtB - sqrtA) // Q96
print(f"穿越区间吃进 USDC ≈ {need1} raw = {Decimal(need1)/10**6:.4f} USDC(不含fee)")
fee1 = need1 * 3 // 1000
print(f"0.3% fee ≈ {fee1} raw = {Decimal(fee1)/10**6:.4f} USDC")

# --- swap 限价:tickUpper + 120(防污染,区间穿完即停) ---
limit_tick = TU + 120
sqrt_limit = tick_to_sqrtX96(limit_tick)
print(f"swap sqrtPriceLimitX96(tick {limit_tick}) = {sqrt_limit}")
print(f"swap amountSpecified = -2500000 (exactIn 2.5 USDC,余量因限价不消耗)")
