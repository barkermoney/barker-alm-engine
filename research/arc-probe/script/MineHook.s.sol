// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DynamicFeeHookStub} from "../src/DynamicFeeHookStub.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// 纯本地计算:为 DynamicFeeHookStub 挖 CREATE2 salt,使地址低 14 位 == 0x3000
/// 不连 RPC 不广播,不碰 USDC precompile
contract MineHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant POOL_MANAGER = 0x2756F3F7bFAf103F4c550f4d24CdCa82B093240A;

    function run() external pure {
        bytes memory initcode =
            abi.encodePacked(type(DynamicFeeHookStub).creationCode, abi.encode(IPoolManager(POOL_MANAGER)));
        bytes32 initHash = keccak256(initcode);
        console.log("initcode hash:");
        console.logBytes32(initHash);
        for (uint256 s = 0; s < 2_000_000; s++) {
            address a = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(s), initHash))))
            );
            if (uint160(a) & 0x3FFF == 0x3000) {
                console.log("salt:", s);
                console.log("hook address:", a);
                return;
            }
        }
        revert("no salt found");
    }
}
