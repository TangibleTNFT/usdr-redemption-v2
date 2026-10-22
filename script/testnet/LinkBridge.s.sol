// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestnetConfig} from "./TestnetConfig.sol";

interface ILzApp {
    function setTrustedRemote(uint16 remoteChainId, bytes calldata path) external;
}

/// @notice Trusts the counterpart wUSDR on the current chain. Run once on each chain after
///         DeployHub and DeploySide.
contract LinkBridge is TestnetConfig {
    function run() external {
        address hub = vm.parseJsonAddress(vm.readFile(HUB_JSON), ".wUSDR");
        address side = vm.parseJsonAddress(vm.readFile(SIDE_JSON), ".wUSDR");
        vm.startBroadcast();
        if (block.chainid == HUB_CHAIN_ID) {
            ILzApp(hub).setTrustedRemote(SIDE_LZ_ID, abi.encodePacked(side, hub));
        } else if (block.chainid == SIDE_CHAIN_ID) {
            ILzApp(side).setTrustedRemote(HUB_LZ_ID, abi.encodePacked(hub, side));
        } else {
            revert("unsupported chain");
        }
        vm.stopBroadcast();
    }
}
