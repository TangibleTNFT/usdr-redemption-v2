// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";

/// @notice Derives testnet/TestnetUSDRRedemption.sol from the audited src/USDRRedemption.sol.
///         The only functional change: SWEEP_DELAY becomes a constructor argument, so testers
///         can reach the swept/closed state without waiting 180 days. Used by
///         script/testnet/GenerateRedemptionCopy.s.sol (writes the file) and
///         test/testnet/TestnetCopy.t.sol (fails if the committed copy drifts from src).
abstract contract RedemptionCopyGen is CommonBase {
    string internal constant SRC = "src/USDRRedemption.sol";
    string internal constant COPY = "testnet/TestnetUSDRRedemption.sol";

    function _generate() internal view returns (string memory s) {
        s = vm.readFile(SRC);
        s = _replaceOnce(s, '"./interfaces/', '"../src/interfaces/');
        s = _replaceOnce(s, '"./interfaces/', '"../src/interfaces/');
        s = _replaceOnce(
            s,
            "contract USDRRedemption is",
            "/// @custom:testnet GENERATED from src/USDRRedemption.sol by testnet/RedemptionCopyGen.sol.\n"
            "///         Identical except that SWEEP_DELAY is a constructor argument. Testnet only.\n"
            "contract TestnetUSDRRedemption is"
        );
        s = _replaceOnce(
            s,
            "uint256 public constant override SWEEP_DELAY = 180 days;",
            "uint256 public immutable override SWEEP_DELAY;"
        );
        s = _replaceOnce(
            s,
            "constructor(address usdr_, address usdc_, uint256 rate_, uint256 totalSupply_, address owner_) Ownable(owner_) {\n",
            "constructor(\n        address usdr_,\n        address usdc_,\n        uint256 rate_,\n        uint256 totalSupply_,\n"
            "        address owner_,\n        uint256 sweepDelay_\n    ) Ownable(owner_) {\n        SWEEP_DELAY = sweepDelay_;\n"
        );
    }

    /// @dev vm.replace replaces every occurrence; require exactly one match per step so a
    ///      changed source fails loudly instead of producing a silently different copy.
    function _replaceOnce(string memory s, string memory from, string memory to) private pure returns (string memory) {
        uint256 i = vm.indexOf(s, from);
        require(i != type(uint256).max, string.concat("pattern not found: ", from));
        string memory head = _slice(s, 0, i);
        string memory tail = _slice(s, i + bytes(from).length, bytes(s).length);
        return string.concat(head, to, tail);
    }

    function _slice(string memory s, uint256 a, uint256 b) private pure returns (string memory) {
        bytes memory out = new bytes(b - a);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(s, 0x20), a), sub(b, a))
        }
        return string(out);
    }
}
