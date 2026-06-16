// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IUSDRRedemption} from "../../src/interfaces/IUSDRRedemption.sol";

/// @notice Malicious 6-decimal "USDC" whose transfer re-enters {IUSDRRedemption.redeem}
///         during the redeem payout, used to prove the nonReentrant guard trips.
contract ReentrantUSDC is ERC20 {
    IUSDRRedemption public target;
    bool public attack;

    constructor() ERC20("Reentrant USDC", "rUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTarget(IUSDRRedemption target_) external {
        target = target_;
    }

    function setAttack(bool on) external {
        attack = on;
    }

    /// @dev On the payout transfer, re-enter redeem before completing — the guard must revert.
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attack) {
            attack = false;
            target.redeem(1); // reverts with ReentrancyGuardReentrantCall, bubbling up
        }
        return super.transfer(to, amount);
    }
}
