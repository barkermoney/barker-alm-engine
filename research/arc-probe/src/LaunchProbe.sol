// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract ProbeToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, address to) {
        name = n; symbol = s;
        totalSupply = 1_000_000_000e18;
        balanceOf[to] = totalSupply;
        emit Transfer(address(0), to, totalSupply);
    }
    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v; balanceOf[to] += v;
        emit Transfer(msg.sender, to, v); return true;
    }
    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        emit Approval(msg.sender, sp, v); return true;
    }
    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v; balanceOf[t] += v;
        emit Transfer(f, t, v); return true;
    }
}

interface IUniswapV3Factory {
    function createPool(address, address, uint24) external returns (address);
}
interface IUniswapV3PoolMin {
    function initialize(uint160) external;
}

// 一笔交易 = 发币 + 建 1% 费率池 + 初始化价格（Pons 模式核心探针）
contract LaunchProbe {
    IUniswapV3Factory public immutable factory;
    address public immutable usdc;
    event Launched(address token, address pool);

    constructor(address f, address u) { factory = IUniswapV3Factory(f); usdc = u; }

    function launch(string calldata n, string calldata s) external returns (address token, address pool) {
        token = address(new ProbeToken(n, s, msg.sender));
        pool = factory.createPool(token, usdc, 10000);
        IUniswapV3PoolMin(pool).initialize(79228162514264337593543950336); // sqrtPriceX96 = 2^96
        emit Launched(token, pool);
    }
}
