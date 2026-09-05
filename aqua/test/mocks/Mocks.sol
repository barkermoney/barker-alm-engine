// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @custom:modification Barker — 2026-09-05, ETHOnline 2026. Test doubles; new file.

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenMock is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice An ERC-4626 vault whose withdrawable amount can be throttled independently of share price.
/// @dev Real vaults route deposits into positions that are not instantly redeemable — MetaMorpho
///   vaults such as steakUSDC hold most assets in Morpho markets, and `maxWithdraw` falls below the
///   share value whenever those markets are fully utilised. A vault mock that always redeems in full
///   would let a bug through: the guard reading `convertToAssets` instead of `maxWithdraw` would
///   pass every test and still over-quote against the real thing.
contract ThrottledVaultMock is ERC4626 {
    uint256 public liquidityCap = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Throttled Vault", "tVLT") { }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 shareValue = super.maxWithdraw(owner);
        return shareValue < liquidityCap ? shareValue : liquidityCap;
    }
}

/// @notice A vault reporting an asset that is not the token being paid out.
contract WrongAssetVaultMock is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Wrong Asset Vault", "wVLT") { }
}

/// @notice A contract at a vault address that is not a vault at all.
contract NotAVault {
    // Deliberately empty: `asset()` on this address reverts, which is the behaviour under test.
}
