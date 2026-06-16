// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {USDRRedemption} from "../src/USDRRedemption.sol";

/// @title  USDRRedemption deployment script (Polygon, chainId 137)
///
/// @notice Deploys the immutable (non-upgradeable) redemption contract. All pending
///         values are deploy-time parameters supplied via env vars:
///
///           RATE   - USDC raw units (6 dp) per 1 whole USDR. ~$0.54, exact figure TBC.
///                    $0.54 -> 540000, $0.5417 -> 541700. CONFIRM WITH JAG BEFORE DEPLOY.
///           USDC   - the USDC token paid out (TBC):
///                      native USDC: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
///                      USDC.e:      0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
///           OWNER  - the Gnosis Safe multisig that will own the contract.
///           USDR   - optional override; defaults to the live Polygon USDR token.
///
///         Usage:
///           RATE=541700 \
///           USDC=0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 \
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
///         fund() is owner-only and pulls the USDC from the Safe; every call resets the
///         180-day sweep clock. Do NOT send USDC to the contract with a raw transfer —
///         it would still be redeemable but would not stamp the funding clock.
///
///         sweep(to) — once 180 days have passed since the last fund() call, the Safe
///         executes redemption.sweep(treasury) to recover whatever USDC remains. Before
///         the deadline this reverts with SweepLocked(unlockTime); the public view
///         sweepUnlockTime() reports the earliest possible moment.
///
///         rescueERC20(token, to) — Safe-only recovery for stray tokens; rejects USDC
///         so the sweep timelock can never be bypassed.
contract DeployUSDRRedemption is Script {
    /// @dev Live Polygon USDR (9 decimals). The old/migrated token at
    ///      0xb5dfabd7ff7f83bab83995e72a52b97abb7bcf63 must NOT be used.
    address internal constant DEFAULT_USDR = 0x40379a439D4F6795B6fc9aa5687dB461677A2dBa;

    function run() external returns (USDRRedemption redemption) {
        uint256 rate = vm.envUint("RATE");
        address usdc = vm.envAddress("USDC");
        address owner = vm.envAddress("OWNER");
        address usdr = vm.envOr("USDR", DEFAULT_USDR);

        // Sanity rails for the ~$0.54 figure: a fat-fingered RATE (wrong decimals,
        // dollars instead of micro-dollars, ...) is unrecoverable post-deploy.
        require(rate >= 400_000 && rate <= 700_000, "RATE outside ~$0.40-$0.70 sanity band");

        vm.startBroadcast();
        redemption = new USDRRedemption(usdr, usdc, rate, owner);
        vm.stopBroadcast();

        console.log("USDRRedemption deployed:", address(redemption));
        console.log("  USDR :", usdr);
        console.log("  USDC :", usdc);
        console.log("  rate :", rate, "(USDC units per 1 USDR)");
        console.log("  owner:", owner);
    }
}
