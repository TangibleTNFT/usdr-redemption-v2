// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {USDRRedemption} from "../src/USDRRedemption.sol";

/// @title  USDRRedemption deployment script (Polygon, chainId 137)
///
/// @notice Deploys the immutable (non-upgradeable) redemption contract. Security-critical
///         production values are hardcoded; only the Safe owner is supplied via an env var:
///
///           OWNER - the already-deployed Gnosis Safe multisig that will own the contract.
///
///         Usage:
///           OWNER=<gnosis-safe-address> \
///           forge script script/DeployUSDRRedemption.s.sol \
///             --rpc-url "$POLYGON_RPC_URL" --broadcast --verify -i 1 --sender <deployer>
///
/// @dev    ── No USDR token setup is needed ─────────────────────────────────────────
///         The Polygon USDR token's `burn(account, amount)` is permissionless and
///         allowance-based (it is NOT gated by BURNER_ROLE), so the redemption contract
///         burns USDR directly from each redeemer via the allowance the redeemer grants
///         it. There is NO role grant and NO Gnosis Safe setup transaction to execute
///         against the USDR token after deployment. The deployer key needs no special
///         privileges either — ownership is assigned to the Safe in the constructor.
///
///         ── Gnosis Safe operational flow ──────────────────────────────────────────
///         fund(amount) — each time proceeds arrive, the Safe executes (ideally as one
///         batched transaction via the Safe Transaction Builder):
///           1. USDC.approve(redemption, amount)
///           2. redemption.fund(amount)
///         fund() is owner-only and pulls the USDC from the Safe. It rejects anything
///         beyond expectedFunding() = ceil(TOTAL_SUPPLY * rate / 1e9); read
///         remainingFunding() for the exact amount that tops the contract up to the penny.
///         Do NOT send USDC to the contract with a raw transfer. If it happens, the Safe may
///         recognize that unaccounted balance through fundFromBalance(amount), subject to the
///         same funding cap, or leave it for the final sweep.
///
///         setRate(newRate) — raises the rate (only ever upward). This raises
///         expectedFunding(); once the difference is funded, every holder — including those
///         who already redeemed — can claim the extra. Raising the rate un-arms the sweep
///         countdown until the contract is fully funded again.
///
///         sweep(to) — allowed 180 days after the contract becomes FULLY funded (see
///         sweepUnlockTime(); it reports type(uint256).max while under-funded). It takes the
///         ENTIRE USDC balance and permanently closes the contract: this is the single
///         deadline for holders who never presented their USDR and for holders who
///         presented it but never claimed the remainder. If full funding is never reached,
///         no sweep is ever possible.
///
///         rescueERC20(token, to) — Safe-only recovery for stray tokens; rejects USDC
///         so the sweep timelock can never be bypassed.
contract DeployUSDRRedemption is Script {
    uint256 internal constant POLYGON_CHAIN_ID = 137;

    /// @dev Live Polygon USDR (9 decimals). The old/migrated token at
    ///      0xb5dfabd7ff7f83bab83995e72a52b97abb7bcf63 must NOT be used.
    address internal constant USDR = 0x40379a439D4F6795B6fc9aa5687dB461677A2dBa;

    /// @dev Native Circle USDC on Polygon, deliberately not bridged USDC.e.
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    /// @dev Initial $0.532 per USDR. The owner may only raise it after deployment.
    uint256 internal constant RATE = 532_000;

    /// @dev Tangible's agreed accessible supply: 35,909,552 USDR. Immutable denominator.
    uint256 internal constant TOTAL_USDR_SUPPLY = 35_909_552e9;

    function run() external returns (USDRRedemption redemption) {
        require(block.chainid == POLYGON_CHAIN_ID, "Polygon deployment only (chainId 137)");
        address owner = vm.envAddress("OWNER");
        // This rejects EOAs and undeployed/counterfactual addresses. The broadcast operator
        // must still compare OWNER with Tangible's independently approved Safe address.
        require(owner.code.length != 0, "OWNER must be a deployed contract");

        // Informational: the on-chain supply legitimately differs because the agreed figure
        // excludes balances that are irrecoverably stuck. Log both values so
        // the production broadcast record captures the security-critical assumption.
        uint256 onChainSupply = IERC20(USDR).totalSupply();
        console.log("USDR on-chain totalSupply:", onChainSupply);
        console.log("accessible supply         :", TOTAL_USDR_SUPPLY);
        if (onChainSupply > TOTAL_USDR_SUPPLY) {
            console.log("  excluded/inaccessible supply:", onChainSupply - TOTAL_USDR_SUPPLY);
        } else {
            console.log("  WARNING configured exceeds on-chain by:", TOTAL_USDR_SUPPLY - onChainSupply);
        }

        vm.startBroadcast();
        redemption = new USDRRedemption(USDR, USDC, RATE, TOTAL_USDR_SUPPLY, owner);
        vm.stopBroadcast();

        console.log("USDRRedemption deployed:", address(redemption));
        console.log("  USDR        :", USDR);
        console.log("  USDC        :", USDC);
        console.log("  rate        :", RATE, "(USDC units per 1 USDR)");
        console.log("  totalSupply :", TOTAL_USDR_SUPPLY, "(raw USDR, 9 dp)");
        console.log("  expected funding (raw USDC, 6 dp):", redemption.expectedFunding());
        console.log("  owner       :", owner);

        _writeRegistry(address(redemption), USDR, USDC, RATE, TOTAL_USDR_SUPPLY, owner);
        console.log("Recorded -> deployments/%s.json", vm.toString(block.chainid));
        console.log("Verify on Polygonscan with --verify (POLYGONSCAN_API_KEY set).");
    }

    /// @dev Durable record of the deployed address (and config) for operational reference,
    ///      so it need not be scraped from broadcast logs. Project-relative path; needs fs
    ///      write permission (foundry.toml).
    function _writeRegistry(
        address redemption,
        address usdr,
        address usdc,
        uint256 rate,
        uint256 totalSupply,
        address owner
    ) internal {
        string memory obj = "usdr-redemption-deployment";
        vm.serializeAddress(obj, "usdr", usdr);
        vm.serializeAddress(obj, "usdc", usdc);
        vm.serializeUint(obj, "rate", rate);
        vm.serializeUint(obj, "totalSupply", totalSupply);
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "owner", owner);
        string memory json = vm.serializeAddress(obj, "redemption", redemption);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }
}
