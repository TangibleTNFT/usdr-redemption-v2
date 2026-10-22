// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {TestnetConfig} from "./TestnetConfig.sol";
import {SideFaucet, IChildWUSDR} from "../../testnet/Faucets.sol";

interface IChildWUSDRAdmin {
    function initialize(address owner, address lzEndpoint) external;
    function setMigrator(address migrator) external;
    function setUseCustomAdapterParams(bool) external;
    function setMinDstGas(uint16 dstChainId, uint16 packetType, uint256 minGas) external;
}

/// @notice Side-chain part of the testnet replica (Sepolia): the live ChildWUSDR bytecode,
///         configured like mainnet after 2026-10-20 (custom adapter params, 200k min gas),
///         and the faucet as its migrator.
contract DeploySide is TestnetConfig {
    uint256 internal constant GAS_DRIP = 0.03 ether;

    function run() external {
        require(block.chainid == SIDE_CHAIN_ID, "side = Sepolia");
        uint256 faucetGas = vm.envOr("FAUCET_GAS", uint256(2 ether));

        vm.startBroadcast();
        address me = msg.sender;
        // Sepolia charges far more gas for new code and state than forge's local EVM
        // (ChildWUSDR: 26.65M gas on 2026-10-21 vs ~3.7M simulated), so run this script with
        // --skip-simulation: every transaction's gas limit is then estimated by the node.
        address child = _deployRaw("testnet/artifacts/ChildWUSDR.json");
        IChildWUSDRAdmin(child).initialize(me, SIDE_LZ_ENDPOINT);
        IChildWUSDRAdmin(child).setUseCustomAdapterParams(true);
        IChildWUSDRAdmin(child).setMinDstGas(HUB_LZ_ID, 0, MIN_DST_GAS);

        SideFaucet faucet = new SideFaucet(IChildWUSDR(child), GAS_DRIP);
        IChildWUSDRAdmin(child).setMigrator(address(faucet));
        (bool ok,) = address(faucet).call{value: faucetGas}("");
        require(ok, "faucet funding failed");
        vm.stopBroadcast();

        string memory k = "side";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "lzChainId", SIDE_LZ_ID);
        vm.serializeAddress(k, "lzEndpoint", SIDE_LZ_ENDPOINT);
        vm.serializeAddress(k, "wUSDR", child);
        string memory out = vm.serializeAddress(k, "faucet", address(faucet));
        vm.writeJson(out, SIDE_JSON);
        console.log("side written to", SIDE_JSON);
    }
}
