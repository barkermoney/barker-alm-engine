// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BarkerV4Positions} from "../src/BarkerV4Positions.sol";
import {BarkerDynamicFeeHook} from "../src/BarkerDynamicFeeHook.sol";

/// @notice Deploys the Arc leg: the position manager, and the dynamic fee hook at a mined address.
///
/// @dev 🔴 **Read this before adding anything to this script.**
///
///      On Arc, USDC is a native precompile behind an ERC-20 shell, and Foundry's EVM does not
///      implement it. Any call that touches USDC reverts with `StackUnderflow` during simulation —
///      and because `forge script` simulates the whole script before broadcasting *any* of it, one
///      USDC-touching line makes the entire script silently broadcast nothing while still printing
///      a plausible success. A deployment that never happened looks exactly like one that did.
///
///      This script is therefore restricted to operations that provably do not move USDC:
///      contract deployment, and `initialize` (which creates a pool but transfers nothing). Opening,
///      closing and swapping all move USDC and are driven through `cast` against a real node
///      instead — see `script/lifecycle.sh`.
///
///      Do not "just add a mint here". That is the trap this comment exists to prevent.
///
/// Usage:
///   1. `forge script script/MineHookSalt.s.sol:MineHookSalt` and note the salt
///   2. `HOOK_SALT=<salt> forge script script/DeployArc.s.sol:DeployArc --rpc-url arc_testnet --broadcast`
contract DeployArc is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address governance = vm.envAddress("GOVERNANCE");
        bytes32 hookSalt = vm.envBytes32("HOOK_SALT");
        uint24 baseFee = uint24(vm.envOr("BASE_FEE", uint256(3000)));
        uint24 maxFee = uint24(vm.envOr("MAX_FEE", uint256(50_000)));
        uint24 surgePerTick = uint24(vm.envOr("SURGE_PER_TICK", uint256(20)));
        uint32 decayBlocks = uint32(vm.envOr("DECAY_BLOCKS", uint256(300)));

        vm.startBroadcast();

        BarkerV4Positions positions = new BarkerV4Positions(IPoolManager(poolManager), governance);
        console2.log("BarkerV4Positions   :", address(positions));

        // CREATE2 through the canonical deployer, so the address matches what the miner computed.
        bytes memory hookInitCode = abi.encodePacked(
            type(BarkerDynamicFeeHook).creationCode,
            abi.encode(IPoolManager(poolManager), governance, baseFee, maxFee, surgePerTick, decayBlocks)
        );
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(hookSalt, hookInitCode));
        require(ok, "hook CREATE2 deployment failed");

        // safe: CREATE2 deployer returns exactly the 20-byte deployed address
        // forge-lint: disable-next-line(unsafe-typecast)
        address hook = address(uint160(bytes20(ret)));
        console2.log("BarkerDynamicFeeHook:", hook);

        vm.stopBroadcast();

        // The hook's own constructor already rejects a wrong address, so reaching here means the
        // flags are right. Asserted again anyway: this is the failure that is invisible later.
        require(
            uint160(hook) & Hooks.ALL_HOOK_MASK == (Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
            "hook address lacks required flags"
        );
        require(hook.code.length > 0, "hook has no code");
    }
}
