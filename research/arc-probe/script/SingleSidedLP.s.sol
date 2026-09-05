// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

interface INPM {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata) external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    struct DecreaseParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function decreaseLiquidity(DecreaseParams calldata) external payable returns (uint256 amount0, uint256 amount1);
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(CollectParams calldata) external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1);
}

// 极简 swapper：直接对 pool swap，callback 里付 token1(USDC) 买 token0(meme)
contract Swapper {
    address immutable usdc;
    constructor(address _usdc) { usdc = _usdc; }
    function push(address pool, uint256 amountInUsdc) external {
        // zeroForOne=false: 用 token1(USDC) 换 token0(meme)，价格上行
        uint160 MAX = 1461446703485210103287273052203988822378723970342;
        IPool(pool).swap(msg.sender, false, int256(amountInUsdc), MAX - 1, "");
    }
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        // 我们买 token0，需要付 token1(USDC) = 正的 amount1Delta
        if (amount1Delta > 0) IERC20(usdc).transfer(msg.sender, uint256(amount1Delta));
    }
}

contract SingleSidedLP is Script {
    address constant TOKEN = 0x18B16C43d54E4D615d00532D2dc070F2F79f66A5; // ProbeToken (token0, 18dec)
    address constant USDC  = 0x3600000000000000000000000000000000000000; // token1, 6dec
    address constant POOL  = 0x601B8b19a82A7E10c9F3E31fF1d784Ffc2C47057;
    address constant NPM   = 0x646E3cCd584b315F235aD269C0893a125D9F38dc;
    uint24  constant FEE   = 10000;

    function run() external {
        uint256 pk = vm.envUint("PK");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);

        // --- 0. 记录初始 ---
        (, int24 tick0,,,,,) = IPool(POOL).slot0();
        console.log("== BEFORE ==");
        console.logInt(tick0);
        console.log("my meme:", IERC20(TOKEN).balanceOf(me));
        console.log("my usdc:", IERC20(USDC).balanceOf(me));

        // --- 1. 建单边止盈仓：token0(meme) only，区间 [200, 4000]，全在现价(tick0=0)之上 ---
        IERC20(TOKEN).approve(NPM, type(uint256).max);
        INPM.MintParams memory mp = INPM.MintParams({
            token0: TOKEN, token1: USDC, fee: FEE,
            tickLower: 200, tickUpper: 4000,
            amount0Desired: 1e22, amount1Desired: 0, // 10,000 meme，纯单边
            amount0Min: 0, amount1Min: 0,
            recipient: me, deadline: 9999999999
        });
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = INPM(NPM).mint(mp);
        console.log("== MINTED single-sided ==");
        console.log("tokenId:", tokenId, "liq:", liq);
        console.log("meme in:", a0, "usdc in:", a1); // 期望 a1=0

        // --- 2. 自己当买家：swap USDC->meme 推价上行，穿进止盈区间 ---
        Swapper sw = new Swapper(USDC);
        IERC20(USDC).transfer(address(sw), 5_000000); // 给 swapper 5 USDC
        sw.push(POOL, 5_000000);
        (, int24 tick1,,,,,) = IPool(POOL).slot0();
        console.log("== AFTER SWAP ==");
        console.logInt(tick1); // 期望 > 200，价格已进区间

        // --- 3. 拆仓：看单边 meme 仓被自动卖成了多少 USDC + 吃了多少手续费 ---
        (,,,,,,, uint128 liqNow,,,,) = INPM(NPM).positions(tokenId);
        INPM(NPM).decreaseLiquidity(INPM.DecreaseParams({
            tokenId: tokenId, liquidity: liqNow, amount0Min: 0, amount1Min: 0, deadline: 9999999999
        }));
        (uint256 got0, uint256 got1) = INPM(NPM).collect(INPM.CollectParams({
            tokenId: tokenId, recipient: me, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
        console.log("== CLOSED position (principal+fees) ==");
        console.log("meme back:", got0, "usdc back(+fees):", got1);
        // 结论：got0 < 10000 meme（部分被卖），got1 > 0（收到 USDC = 止盈 + 手续费）

        vm.stopBroadcast();
    }
}
