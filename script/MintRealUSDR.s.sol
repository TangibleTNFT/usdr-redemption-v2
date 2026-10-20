// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

interface IUSDRAdmin {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
    function mint(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice One-off: mint the re.al USDR supply (re.al is shut down) on Polygon to the Tangible
///         Labs Safe, so re.al holders can be paid out through the redemption contract.
///         The broadcaster (USDR role admin) grants itself MINTER_ROLE, mints, and renounces
///         the role again, leaving no minter behind.
///         Executed 2026-10-20: forge under-estimated the mint's gas (limit 99,546, needs ~105k),
///         so the mint (0xa865c809…) ran out of gas after the grant (0x827be697…) had succeeded.
///         Mint (0xf7c8c5e2…) and renounce (0xdb328105…) were then sent by hand with cast.
///         If ever rerun, pass --gas-estimate-multiplier 200.
contract MintRealUSDR is Script {
    IUSDRAdmin internal constant USDR = IUSDRAdmin(0x40379a439D4F6795B6fc9aa5687dB461677A2dBa);
    /// @dev USDR's roles.sol: keccak256("MINTER"); the token exposes no getter for it.
    bytes32 internal constant MINTER = keccak256("MINTER");
    address internal constant SAFE = 0xAF8A1548Fd69a59Ce6A2a5f308bCC4698E1Db2E5;

    /// @dev re.al USDR totalSupply = sum of the re.al holder snapshot: 4,563,236.782291263 USDR.
    uint256 internal constant AMOUNT = 4_563_236_782_291_263;

    function run() external {
        require(block.chainid == 137, "Polygon only");
        bytes32 minter = MINTER;
        uint256 safeBefore = USDR.balanceOf(SAFE);
        uint256 supplyBefore = USDR.totalSupply();

        vm.startBroadcast();
        USDR.grantRole(minter, msg.sender);
        USDR.mint(SAFE, AMOUNT);
        USDR.renounceRole(minter, msg.sender);
        vm.stopBroadcast();

        uint256 got = USDR.balanceOf(SAFE) - safeBefore;
        console.log("Safe received (raw, 9 dp):", got);
        console.log("totalSupply delta         :", USDR.totalSupply() - supplyBefore);
        console.log("broadcaster still minter  :", USDR.hasRole(minter, msg.sender));
        require(!USDR.hasRole(minter, msg.sender), "minter role left behind");
        require(got + 1 >= AMOUNT && got <= AMOUNT + 1, "minted amount off");
    }
}
