// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IUSDRRedemption} from "../../src/interfaces/IUSDRRedemption.sol";

/// @notice Malicious 6-decimal "USDC" whose transfer re-enters the redemption contract
///         during a payout ({IUSDRRedemption.redeem} or {IUSDRRedemption.claim}), used to
///         prove the nonReentrant guard trips.
contract ReentrantUSDC is ERC20 {
    enum Attack {
        None,
        Redeem,
        Claim
    }

    IUSDRRedemption public target;
    Attack public attack;

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

    function setAttack(Attack attack_) external {
        attack = attack_;
    }

    /// @dev On the payout transfer, re-enter before completing — the guard must revert.
    function transfer(address to, uint256 amount) public override returns (bool) {
        Attack mode = attack;
        if (mode != Attack.None) {
            attack = Attack.None;
            if (mode == Attack.Redeem) target.redeem(1); // reverts with ReentrancyGuardReentrantCall
            else target.claim();
        }
        return super.transfer(to, amount);
    }
}
