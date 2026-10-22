// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet stand-in for Polygon USDR: 9 decimals, the real token's allowance-based
///         `burn(account, amount)` (used by the redemption contract), and the real
///         `liquidityIndex()` that WrappedUSDR prices wUSDR with. Anyone may mint.
contract TestUSDR is ERC20 {
    /// @dev Polygon USDR.liquidityIndex() as of 2026-10-21 (USDR no longer rebases), so
    ///      1 wUSDR unwraps to ~1.0791 USDR exactly as on mainnet.
    uint256 public constant liquidityIndex = 1_079_077_720_927_108_122_860_220_081;

    constructor() ERC20("Real USD (testnet)", "USDR") {}

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    /// @notice Mint test USDR. `amount` in raw units (9 decimals: 1 USDR = 1e9).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address account, uint256 amount) external {
        if (msg.sender != account) _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }
}

/// @notice Testnet stand-in for native USDC: 6 decimals. Anyone may mint.
contract TestUSDC is ERC20 {
    constructor() ERC20("USD Coin (testnet)", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint test USDC. `amount` in raw units (6 decimals: 1 USDC = 1e6).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
