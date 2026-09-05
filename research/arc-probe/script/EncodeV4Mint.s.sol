// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Plan, Planner} from "v4-periphery/test/shared/Planner.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";

/// 本地纯计算:输出 posm.modifyLiquidities 的 unlockData(mint / burn),cast send 用
/// 用法(env 传参):
///   MODE=mint C0=0x.. C1=0x.. FEE=2925 SPACING=29 HOOKS=0x0 TL=-100 TU=-50 LIQ=123 RECIPIENT=0x.. \
///   forge script script/EncodeV4Mint.s.sol -vv
///   MODE=burn TOKEN_ID=123 ... 同上(burn 只需 key + TOKEN_ID)
contract EncodeV4Mint is Script {
    using Planner for Plan;

    function run() external view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("C0")),
            currency1: Currency.wrap(vm.envAddress("C1")),
            fee: uint24(vm.envUint("FEE")),
            tickSpacing: int24(int256(vm.envInt("SPACING"))),
            hooks: IHooks(vm.envOr("HOOKS", address(0)))
        });
        string memory mode = vm.envString("MODE");

        Plan memory planner = Planner.init();
        bytes memory data;
        if (keccak256(bytes(mode)) == keccak256("mint")) {
            planner.add(
                Actions.MINT_POSITION,
                abi.encode(
                    key,
                    int24(int256(vm.envInt("TL"))),
                    int24(int256(vm.envInt("TU"))),
                    vm.envUint("LIQ"),
                    type(uint128).max,
                    type(uint128).max,
                    vm.envAddress("RECIPIENT"),
                    bytes("")
                )
            );
            planner.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
            planner.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
            if (Currency.unwrap(key.currency0) == address(0)) {
                // native:posm 不退多余 msg.value,必须 SWEEP 找零回 msgSender(router)
                planner.add(Actions.SWEEP, abi.encode(key.currency0, ActionConstants.MSG_SENDER));
            }
            data = planner.encode();
        } else {
            planner.add(
                Actions.BURN_POSITION,
                abi.encode(vm.envUint("TOKEN_ID"), uint128(0), uint128(0), bytes(""))
            );
            data = planner.finalizeModifyLiquidityWithClose(key);
        }
        console.log("unlockData:");
        console.logBytes(data);
    }
}
