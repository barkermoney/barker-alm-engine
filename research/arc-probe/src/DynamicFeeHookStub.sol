// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// 最小 V4 hook 骨架:为动态费率/quote-only 费率铺路
/// 权限位 = BEFORE_INITIALIZE(1<<13) | AFTER_INITIALIZE(1<<12) = 0x3000,地址低 14 位须等于 0x3000(CREATE2 挖矿)
/// 挂动态费率池(fee=0x800000)时,afterInitialize 把起始 LP 费率设为 1%
contract DynamicFeeHookStub {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external returns (bytes4) {
        require(msg.sender == address(manager), "mgr");
        manager.updateDynamicLPFee(key, 10000); // 1%
        return IHooks.afterInitialize.selector;
    }
}
