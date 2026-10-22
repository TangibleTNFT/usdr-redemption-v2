// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {RedemptionCopyGen} from "../../testnet/RedemptionCopyGen.sol";

/// @notice Regenerates testnet/TestnetUSDRRedemption.sol from src/USDRRedemption.sol.
contract GenerateRedemptionCopy is Script, RedemptionCopyGen {
    function run() external {
        vm.writeFile(COPY, _generate());
    }
}
