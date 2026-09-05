// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// 单边集中流动性原语探针:V4 建/铸/换/平薄封装(Arc 测试网,owner 单签)
/// 所有资金动作经 unlock/unlockCallback;欠款从 owner transferFrom,应收直接 take 给 owner
contract V4SidedHelper is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    address public immutable owner;

    uint8 private constant ACT_MODIFY = 0;
    uint8 private constant ACT_SWAP = 1;

    constructor(IPoolManager m) {
        manager = m;
        owner = msg.sender;
    }

    receive() external payable {} // native take/找零

    modifier onlyOwner() {
        require(msg.sender == owner, "auth");
        _;
    }

    function initPool(PoolKey calldata key, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick) {
        return manager.initialize(key, sqrtPriceX96);
    }

    /// liquidityDelta > 0 铸仓(须先 approve 本合约),< 0 平仓
    function modify(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        payable
        onlyOwner
        returns (BalanceDelta delta)
    {
        bytes memory res = manager.unlock(abi.encode(ACT_MODIFY, abi.encode(key, tickLower, tickUpper, liquidityDelta)));
        delta = abi.decode(res, (BalanceDelta));
    }

    /// amountSpecified < 0 = exactIn;sqrtPriceLimitX96 必设(防把空段顶到极限 tick)
    function swapExact(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        payable
        onlyOwner
        returns (BalanceDelta delta)
    {
        bytes memory res = manager.unlock(abi.encode(ACT_SWAP, abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96)));
        delta = abi.decode(res, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "mgr");
        (uint8 act, bytes memory payload) = abi.decode(raw, (uint8, bytes));
        PoolKey memory key;
        BalanceDelta delta;
        if (act == ACT_MODIFY) {
            (PoolKey memory k, int24 tl, int24 tu, int256 ld) = abi.decode(payload, (PoolKey, int24, int24, int256));
            key = k;
            (delta,) = manager.modifyLiquidity(k, ModifyLiquidityParams(tl, tu, ld, bytes32(0)), "");
        } else {
            (PoolKey memory k, bool zf1, int256 amt, uint160 lim) = abi.decode(payload, (PoolKey, bool, int256, uint160));
            key = k;
            delta = manager.swap(k, SwapParams(zf1, amt, lim), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            if (Currency.unwrap(c) == address(0)) {
                manager.settle{value: uint256(uint128(-amt))}(); // native:helper 需随调用带足 msg.value
            } else {
                manager.sync(c);
                IERC20Min(Currency.unwrap(c)).transferFrom(owner, address(manager), uint256(uint128(-amt)));
                manager.settle();
            }
        } else if (amt > 0) {
            manager.take(c, owner, uint256(uint128(amt)));
        }
    }

    // ---- views ----
    function slot0(PoolKey calldata key)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return manager.getSlot0(key.toId());
    }

    function positionInfo(PoolKey calldata key, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        return manager.getPositionInfo(key.toId(), address(this), tickLower, tickUpper, bytes32(0));
    }

    function poolLiquidity(PoolKey calldata key) external view returns (uint128) {
        return manager.getLiquidity(key.toId());
    }
}
