// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

/// @notice Shared constants for the testnet replica: Arbitrum Sepolia plays Polygon (the hub with
///         USDR, wUSDR and the redemption), Sepolia plays a side chain with bridged wUSDR.
///         LayerZero v1 delivers Sepolia -> Arbitrum Sepolia (tested 2026-10-21); the reverse
///         direction is not delivered by LayerZero's testnet executor, so it is not supported.
abstract contract TestnetConfig is Script {
    uint256 internal constant HUB_CHAIN_ID = 421614; // Arbitrum Sepolia
    uint256 internal constant SIDE_CHAIN_ID = 11155111; // Sepolia
    uint16 internal constant HUB_LZ_ID = 10231;
    uint16 internal constant SIDE_LZ_ID = 10161;
    address internal constant HUB_LZ_ENDPOINT = 0x6098e96a28E02f27B1e6BD381f870F1C8Bd169d3;
    address internal constant SIDE_LZ_ENDPOINT = 0xae92d5aD7583AD66E49A0c67BAd18F6ba52dDDc1;
    uint256 internal constant MIN_DST_GAS = 200_000;

    string internal constant HUB_JSON = "deployments/421614.json";
    string internal constant SIDE_JSON = "deployments/11155111.json";

    function _deployRaw(string memory artifact) internal returns (address addr) {
        bytes memory code = vm.parseJsonBytes(vm.readFile(artifact), ".bytecode");
        assembly ("memory-safe") {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "raw deploy failed");
    }
}
