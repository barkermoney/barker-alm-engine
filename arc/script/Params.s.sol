// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Computes the numbers a lifecycle run needs, and prints them. Sends nothing.
///
/// @dev This split — **Foundry does the arithmetic, `cast` sends the transactions** — is not a
///      style preference. On Arc, USDC is a native precompile that Foundry's EVM does not
///      implement, so any simulated call touching it reverts, and `forge script`'s
///      simulate-then-broadcast means such a script quietly broadcasts nothing while reporting
///      success. Rather than fight that, we let Foundry do what it is good at and cannot get wrong
///      here (tick and liquidity math, pure functions, no state), and hand the resulting integers
///      to `cast`, which talks to a real node and cannot silently skip a transaction.
///
///      Usage:
///        TICK_LOWER=... TICK_UPPER=... AMOUNT0=... forge script script/Params.s.sol:Params
contract Params is Script {
    uint256 internal constant Q96 = 2 ** 96;

    function run() external view {
        int24 tickLower = int24(vm.envOr("TICK_LOWER", int256(0)));
        int24 tickUpper = int24(vm.envOr("TICK_UPPER", int256(0)));
        int24 initTick = int24(vm.envOr("INIT_TICK", int256(0)));
        uint256 amount0 = vm.envOr("AMOUNT0", uint256(0));
        int24 limitOffset = int24(vm.envOr("LIMIT_OFFSET", int256(120)));

        console2.log("--- pool creation ---");
        console2.log("initTick           :", vm.toString(int256(initTick)));
        console2.log("sqrtPriceX96       :", uint256(TickMath.getSqrtPriceAtTick(initTick)));

        if (tickLower == tickUpper) return;

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        console2.log("--- range ---");
        console2.log("tickLower          :", vm.toString(int256(tickLower)));
        console2.log("tickUpper          :", vm.toString(int256(tickUpper)));
        console2.log("sqrtPriceX96 lower :", uint256(sqrtA));
        console2.log("sqrtPriceX96 upper :", uint256(sqrtB));

        if (amount0 > 0) {
            // L such that a range entirely above spot consumes `amount0` of currency0:
            //   L = amount0 * (sqrtA * sqrtB) / (Q96 * (sqrtB - sqrtA))
            uint256 liquidity =
                FullMathLite.mulDiv(amount0, FullMathLite.mulDiv(sqrtA, sqrtB, Q96), uint256(sqrtB - sqrtA));

            console2.log("--- one-sided mint ---");
            console2.log("target amount0     :", amount0);
            console2.log("liquidity          :", liquidity);

            // What the pool will actually debit, recomputed the way v4 rounds it (up).
            uint256 needed0 =
                FullMathLite.mulDivRoundingUp(liquidity, uint256(sqrtB - sqrtA) * Q96, uint256(sqrtA) * uint256(sqrtB));
            console2.log("pool will debit    :", needed0);

            // Cost of walking the price all the way through the range, in currency1, before fees.
            uint256 crossCost1 = FullMathLite.mulDiv(liquidity, uint256(sqrtB - sqrtA), Q96);
            console2.log("cross range costs  :", crossCost1);
        }

        console2.log("--- swap limit ---");
        console2.log("limitTick          :", vm.toString(int256(tickUpper + limitOffset)));
        console2.log("sqrtPriceLimitX96  :", uint256(TickMath.getSqrtPriceAtTick(tickUpper + limitOffset)));
        console2.log("  ^ pin the limit just outside the range: a swap into thin liquidity with no");
        console2.log("    limit walks the price to the extreme tick and poisons the pool.");
    }
}

/// @dev Minimal 512-bit muldiv. `FullMath` lives in v4-core but is not exported for scripts.
library FullMathLite {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        unchecked {
            return (a * b) / denominator;
        }
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = (a * b) / denominator;
            if (mulmod(a, b, denominator) > 0) result++;
        }
    }
}
