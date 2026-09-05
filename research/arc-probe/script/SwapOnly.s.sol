// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 { function transfer(address,uint256) external returns(bool); function balanceOf(address) external view returns(uint256);}
interface IPool {
    function slot0() external view returns (uint160,int24,uint16,uint16,uint16,uint8,bool);
    function swap(address,bool,int256,uint160,bytes calldata) external returns (int256,int256);
}

contract Swapper {
    address immutable usdc;
    constructor(address u){ usdc=u; }
    function push(address pool, uint256 amt) external {
        uint160 MAX = 1461446703485210103287273052203988822378723970342;
        IPool(pool).swap(address(this), false, int256(amt), MAX-1, "");
    }
    function uniswapV3SwapCallback(int256, int256 a1, bytes calldata) external {
        if (a1 > 0) IERC20(usdc).transfer(msg.sender, uint256(a1));
    }
}

contract SwapOnly is Script {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant POOL = 0x601B8b19a82A7E10c9F3E31fF1d784Ffc2C47057;
    function run() external {
        uint256 pk = vm.envUint("PK");
        vm.startBroadcast(pk);
        (,int24 t0,,,,,) = IPool(POOL).slot0();
        console.log("tick before:"); console.logInt(t0);
        Swapper sw = new Swapper(USDC);
        IERC20(USDC).transfer(address(sw), 3_000000);
        sw.push(POOL, 3_000000);
        (,int24 t1,,,,,) = IPool(POOL).slot0();
        console.log("tick after:"); console.logInt(t1);
        console.log("swapper meme recv:", IERC20(0x18B16C43d54E4D615d00532D2dc070F2F79f66A5).balanceOf(address(sw)));
        vm.stopBroadcast();
    }
}
