// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock of the Polygon USDR token for unit tests: 9 decimals and the same
///         allowance-based, pausable `burn(account, amount)` semantics as the real
///         token (burn spends the caller's allowance when caller != account and is
///         gated by a pause flag, mirroring `whenNotPaused`).
contract MockUSDR is ERC20 {
    bool public paused;

    constructor() ERC20("Real USD", "USDR") {}

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function burn(address account, uint256 amount) external {
        require(!paused, "Pausable: paused");
        if (msg.sender != account) {
            _spendAllowance(account, msg.sender, amount);
        }
        _burn(account, amount);
    }
}
