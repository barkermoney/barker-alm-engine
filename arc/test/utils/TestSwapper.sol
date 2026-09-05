// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @notice Test-only swap helper. Not part of the deployed system.
/// @dev Kept deliberately dumb: it exists so tests can push a pool's price around, nothing more.
contract TestSwapper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    uint8 private constant ACT_SWAP = 0;
    uint8 private constant ACT_MODIFY = 1;

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta delta)
    {
        bytes memory res = manager.unlock(
            abi.encode(ACT_SWAP, msg.sender, key, abi.encode(zeroForOne, amountSpecified, sqrtPriceLimitX96))
        );
        delta = abi.decode(res, (BalanceDelta));
    }

    /// @notice Two-sided liquidity, so hook tests have something to swap against.
    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta delta)
    {
        bytes memory res = manager.unlock(
            abi.encode(ACT_MODIFY, msg.sender, key, abi.encode(tickLower, tickUpper, liquidityDelta))
        );
        delta = abi.decode(res, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "mgr");
        (uint8 action, address payer, PoolKey memory key, bytes memory args) =
            abi.decode(raw, (uint8, address, PoolKey, bytes));

        BalanceDelta delta;
        if (action == ACT_SWAP) {
            (bool zeroForOne, int256 amt, uint160 lim) = abi.decode(args, (bool, int256, uint160));
            delta = manager.swap(key, SwapParams(zeroForOne, amt, lim), "");
        } else {
            (int24 tl, int24 tu, int256 ld) = abi.decode(args, (int24, int24, int256));
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(tl, tu, ld, bytes32(0)), "");
        }

        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);

        return abi.encode(delta);
    }

    function _settle(Currency c, int128 amount, address payer) internal {
        if (amount < 0) {
            manager.sync(c);
            IERC20Min(Currency.unwrap(c)).transferFrom(payer, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, payer, uint256(uint128(amount)));
        }
    }
}
