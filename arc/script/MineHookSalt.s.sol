// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BarkerDynamicFeeHook} from "../src/BarkerDynamicFeeHook.sol";

/// @notice Finds a CREATE2 salt that places `BarkerDynamicFeeHook` at an address carrying the
///         permission flags it needs.
///
/// @dev v4 encodes a hook's permissions in the low 14 bits of its own address, so deploying a hook
///      means searching for a salt. There is no miner in `v4-core` — `HookMiner` lives in
///      `v4-periphery`, which this project deliberately does not depend on — so here is ours. It is
///      about twenty lines; the reason to publish it is that a project taking the no-periphery path
///      otherwise has to write this itself, and getting it subtly wrong produces a hook that deploys
///      successfully and is then never called.
///
///      Run it, then pass the salt to the deploy script. Pure computation — no RPC, no broadcast.
contract MineHookSalt is Script {
    /// @dev Canonical CREATE2 deployer, present on Arc testnet (verified) and most EVM chains.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
    uint256 internal constant MAX_ITERATIONS = 500_000;

    function run() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address governance = vm.envAddress("GOVERNANCE");
        uint24 baseFee = uint24(vm.envOr("BASE_FEE", uint256(3000)));
        uint24 maxFee = uint24(vm.envOr("MAX_FEE", uint256(50_000)));
        uint24 surgePerTick = uint24(vm.envOr("SURGE_PER_TICK", uint256(20)));
        uint32 decayBlocks = uint32(vm.envOr("DECAY_BLOCKS", uint256(300)));

        bytes memory creationCode = abi.encodePacked(
            type(BarkerDynamicFeeHook).creationCode,
            abi.encode(IPoolManager(poolManager), governance, baseFee, maxFee, surgePerTick, decayBlocks)
        );
        bytes32 initCodeHash = keccak256(creationCode);

        (bytes32 salt, address hookAddress) = mine(initCodeHash);

        console2.log("hook address :", hookAddress);
        console2.log("flags (hex)  :", vm.toString(bytes32(uint256(uint160(hookAddress) & Hooks.ALL_HOOK_MASK))));
        console2.log("salt         :", vm.toString(salt));
        console2.log("initCodeHash :", vm.toString(initCodeHash));
    }

    function mine(bytes32 initCodeHash) public pure returns (bytes32 salt, address hookAddress) {
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(salt, initCodeHash);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS) {
                return (salt, hookAddress);
            }
        }
        revert("no salt found within MAX_ITERATIONS");
    }

    function computeAddress(bytes32 salt, bytes32 initCodeHash) public pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash)))));
    }
}
