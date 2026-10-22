// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RedemptionCopyGen} from "../../testnet/RedemptionCopyGen.sol";

/// @notice The testnet copy must be exactly what the generator derives from the audited source.
contract TestnetCopyTest is Test, RedemptionCopyGen {
    function test_CopyMatchesSource() public view {
        assertEq(vm.readFile(COPY), _generate(), "regenerate: forge script script/testnet/GenerateRedemptionCopy.s.sol");
    }
}
