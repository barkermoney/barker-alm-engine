#!/usr/bin/env bash
#
# Arc testnet lifecycle: create a pool, open a one-sided take-profit position, let the price run
# through it, close it. One step per invocation, each one transaction, each printing its hash.
#
# 🔴 Why this is a shell script and not a `forge script`.
#
# Arc's USDC is a native precompile behind an ERC-20 shell, and Foundry's EVM does not implement it.
# Any simulated call touching USDC reverts with StackUnderflow — and because `forge script`
# simulates the entire script before broadcasting any of it, a single USDC-touching line makes the
# whole script broadcast NOTHING while still printing what looks like success. We have watched it
# report a mint that never happened.
#
# So: Foundry computes (script/Params.s.sol, pure math, no state), `cast` transacts against a real
# node. `cast send` cannot silently skip a transaction — it either returns a hash or it fails.
#
# Usage:
#   export ARC_PRIVATE_KEY=0x...        # the deployer/operator key
#   ./lifecycle.sh preflight
#   ./lifecycle.sh init-pool
#   ./lifecycle.sh approve
#   ./lifecycle.sh open
#   ./lifecycle.sh status
#   ./lifecycle.sh swap
#   ./lifecycle.sh status
#   ./lifecycle.sh close
#
# DRY_RUN=1 prints the command instead of sending it.

set -euo pipefail

RPC="${ARC_RPC:-https://rpc.testnet.arc.io}"
CHAIN_ID=5042002

# --- pinned addresses (see docs/environment.md) --------------------------------------------------
POOL_MANAGER="${POOL_MANAGER:-0x2756F3F7bFAf103F4c550f4d24CdCa82B093240A}"
USDC=0x3600000000000000000000000000000000000000
BPROBE=0x18B16C43d54E4D615d00532D2dc070F2F79f66A5   # 18-decimal test token from the probe
SWAP_HELPER="${SWAP_HELPER:-0x1B854Ab2cf1CD3e92079E9aaE1f6A20f0FDc8729}"  # probe-era v4 helper, owner-only

# --- filled in after DeployArc runs --------------------------------------------------------------
POSITIONS="${POSITIONS:-}"
HOOK="${HOOK:-}"

# --- pool + position parameters (from script/Params.s.sol) ---------------------------------------
# 1 BPROBE = 0.0001 USDC.  currency0 = BPROBE (lower address), currency1 = USDC.
DYNAMIC_FEE=8388608          # 0x800000, the dynamic-fee sentinel
TICK_SPACING=60
INIT_SQRT_PRICE=791174656804618572554   # tick -368460
TICK_LOWER=-368100                      # +3.7% above spot
TICK_UPPER=-367500                      # +9.9% above spot
LIQUIDITY=6880784485432867              # ~20,000 BPROBE, one-sided
SWAP_LIMIT=835070413329746806640        # tick -367380, just past the range
SWAP_AMOUNT=-2500000                    # exactIn 2.5 USDC; the limit stops it at the range top
POSITION_ID="${POSITION_ID:-1}"

need() { [ -n "${!1:-}" ] || { echo "error: $1 is not set. Run deploy first, or export it." >&2; exit 1; }; }


# Echo the command with the key redacted. `cast send` takes the key as an argument, so a naive
# `echo "+ $*"` prints it in full — into terminal scrollback, CI logs, and session transcripts.
# That is exactly how this project's deployer key ended up sitting in plaintext in 41 places.
run() {
  local shown=()
  local redact=0
  for a in "$@"; do
    if [ "$redact" = "1" ]; then shown+=("<redacted>"); redact=0
    else
      shown+=("$a")
      [ "$a" = "--private-key" ] && redact=1
    fi
  done
  echo "+ ${shown[*]}"
  if [ "${DRY_RUN:-0}" = "1" ]; then echo "  (dry run, not sent)"; return 0; fi
  "$@"
}

send() {
  need ARC_PRIVATE_KEY
  run cast send --rpc-url "$RPC" --private-key "$ARC_PRIVATE_KEY" "$@"
}

key() { need HOOK; echo "($BPROBE,$USDC,$DYNAMIC_FEE,$TICK_SPACING,$HOOK)"; }

case "${1:-}" in

preflight)
  echo "chain id     : $(cast chain-id --rpc-url "$RPC")  (expected $CHAIN_ID)"
  echo "block        : $(cast block-number --rpc-url "$RPC")"
  need ARC_PRIVATE_KEY
  ME=$(cast wallet address --private-key "$ARC_PRIVATE_KEY")
  echo "operator     : $ME"
  echo "USDC (gas)   : $(cast call $USDC 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC")"
  echo "BPROBE       : $(cast call $BPROBE 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC")"
  echo "PoolManager  : $(cast code $POOL_MANAGER --rpc-url "$RPC" | wc -c) bytes of code"
  # `[ -n ... ] && echo` as the last command of a branch makes the whole script exit 1 under
  # `set -e` when the variable is empty. Use if.
  if [ -n "$POSITIONS" ]; then echo "Positions    : $(cast code "$POSITIONS" --rpc-url "$RPC" | wc -c) bytes"; fi
  if [ -n "$HOOK" ]; then echo "Hook         : $(cast code "$HOOK" --rpc-url "$RPC" | wc -c) bytes"; fi
  ;;

init-pool)
  # Creates the pool. Moves no tokens — the hook's afterInitialize sets the base LP fee.
  send "$POOL_MANAGER" 'initialize((address,address,uint24,int24,address),uint160)' \
    "$(key)" "$INIT_SQRT_PRICE"
  ;;

approve)
  # The position manager pulls currency0 from us at open. Upper side = funded in BPROBE, so this
  # never touches USDC beyond gas.
  need POSITIONS
  send $BPROBE 'approve(address,uint256)' "$POSITIONS" \
    115792089237316195423570985008687907853269984665640564039457584007913129639935
  ;;

approve-swap)
  # The swap leg spends USDC, so the helper needs an allowance.
  send $USDC 'approve(address,uint256)' "$SWAP_HELPER" 10000000
  ;;

open)
  # Side 0 = Upper (take-profit ladder). Debits BPROBE only; if it debits any USDC the contract
  # reverts with NotOneSided.
  need POSITIONS
  send "$POSITIONS" 'open((address,address,uint24,int24,address),int24,int24,uint128,uint8)' \
    "$(key)" "$TICK_LOWER" "$TICK_UPPER" "$LIQUIDITY" 0
  ;;

pool-id)
  # PoolId = keccak256(abi.encode(PoolKey)).
  cast keccak "$(cast abi-encode 'f((address,address,uint24,int24,address))' "$(key)")"
  ;;

status)
  need POSITIONS
  echo "--- pool ---"
  # NOTE: there is no `getSlot0` on PoolManager. StateLibrary's getSlot0 is a helper that computes
  # a storage slot and reads it through `extsload`; calling it as a contract method reverts. Off
  # chain we have to do the same slot arithmetic ourselves: POOLS_SLOT = 6.
  PID=$(cast keccak "$(cast abi-encode 'f((address,address,uint24,int24,address))' "$(key)")")
  SLOT=$(cast keccak "$(cast concat-hex "$PID" 0x0000000000000000000000000000000000000000000000000000000000000006)")
  RAW=$(cast call "$POOL_MANAGER" 'extsload(bytes32)(bytes32)' "$SLOT" --rpc-url "$RPC")
  echo "poolId : $PID"
  python3 -c "
v = int('$RAW', 16)
tick = (v >> 160) & 0xFFFFFF
tick -= 1 << 24 if tick >= 1 << 23 else 0
print(f'sqrtPriceX96 : {v & ((1 << 160) - 1)}')
print(f'tick         : {tick}')
print(f'lpFee        : {(v >> 208) & 0xFFFFFF}')
"
  echo "--- position $POSITION_ID ---"
  cast call "$POSITIONS" 'getPosition(uint256)((address,address,uint24,int24,address),int24,int24,uint128,address,uint8,bool)' \
    "$POSITION_ID" --rpc-url "$RPC"
  ;;

swap)
  # Buy BPROBE with USDC to push the price up through the range. zeroForOne=false, exact input,
  # with the price limit pinned just past the range so the swap stops there instead of running away.
  send "$SWAP_HELPER" 'swapExact((address,address,uint24,int24,address),bool,int256,uint160)' \
    "$(key)" false "$SWAP_AMOUNT" "$SWAP_LIMIT"
  ;;

close)
  # Burns the position and pays principal plus fees back to the position owner. After a full
  # crossing this returns USDC and zero BPROBE.
  need POSITIONS
  send "$POSITIONS" 'close(uint256)' "$POSITION_ID"
  ;;

*)
  sed -n '3,30p' "$0"
  exit 1
  ;;
esac
