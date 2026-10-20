// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

interface IChildWUSDR {
    function owner() external view returns (address);
    function useCustomAdapterParams() external view returns (bool);
    function minDstGasLookup(uint16 dstChainId, uint16 packetType) external view returns (uint256);
    function setUseCustomAdapterParams(bool useCustomAdapterParams) external;
    function setMinDstGas(uint16 dstChainId, uint16 packetType, uint256 minGas) external;
}

/// @notice Reopen the LayerZero v1 path from a side-chain wUSDR (OFT) back to Polygon.
///         LayerZero's SendUln301 now rejects empty adapter params (LZ_ULN_InvalidWorkerOptions(0)),
///         and the child contracts were deployed with useCustomAdapterParams=false, which forces
///         empty params. Turning the flag on requires a min destination gas, else sends revert with
///         "LzApp: minGasLimit not set". Fork-tested 2026-10-20 (OP and Base send, Polygon delivery
///         ~95k gas). Holders then send with type-1 adapter params (200k gas) and _toAddress as
///         20 packed bytes. Run once per side chain with the deployer (owner of every child).
contract ReopenWUSDRBridge is Script {
    uint16 internal constant POLYGON_LZ_ID = 109;
    uint16 internal constant PT_SEND = 0;
    uint256 internal constant MIN_DST_GAS = 200_000;

    function child() internal view returns (IChildWUSDR) {
        if (block.chainid == 1 || block.chainid == 10) return IChildWUSDR(0xC03b43d492d904406db2d7D57e67C7e8234bA752);
        if (block.chainid == 42161 || block.chainid == 8453) return IChildWUSDR(0x9483ab65847A447e36d21af1CaB8C87e9712ff93);
        if (block.chainid == 56) return IChildWUSDR(0x9467f15f44A8641389556387b43d9ED3f6981818);
        revert("unsupported chain");
    }

    function run() external {
        IChildWUSDR c = child();
        console.log("chain                 :", block.chainid);
        console.log("child wUSDR           :", address(c));
        console.log("before: custom params :", c.useCustomAdapterParams());
        console.log("before: min dst gas   :", c.minDstGasLookup(POLYGON_LZ_ID, PT_SEND));

        vm.startBroadcast();
        require(c.owner() == msg.sender, "broadcaster is not the owner");
        if (!c.useCustomAdapterParams()) c.setUseCustomAdapterParams(true);
        if (c.minDstGasLookup(POLYGON_LZ_ID, PT_SEND) != MIN_DST_GAS) c.setMinDstGas(POLYGON_LZ_ID, PT_SEND, MIN_DST_GAS);
        vm.stopBroadcast();

        require(c.useCustomAdapterParams(), "flag not set");
        require(c.minDstGasLookup(POLYGON_LZ_ID, PT_SEND) == MIN_DST_GAS, "min gas not set");
        console.log("after: custom params on, min dst gas", MIN_DST_GAS);
    }
}
