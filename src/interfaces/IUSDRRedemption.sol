// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUSDR} from "./IUSDR.sol";

/// @title IUSDRRedemption
/// @notice External interface for the USDR Redemption v2 contract — the full public API,
///         events, and errors an integrator needs to interact with and index a deployment.
interface IUSDRRedemption {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on every successful redemption.
    /// @param redeemer   Holder whose USDR was burned (always msg.sender).
    /// @param receiver   Address the USDC was paid to.
    /// @param usdrAmount USDR burned, in 9-decimal raw units.
    /// @param usdcAmount USDC paid out, in 6-decimal raw units.
    event Redeemed(address indexed redeemer, address indexed receiver, uint256 usdrAmount, uint256 usdcAmount);

    /// @notice Emitted on every funding; each one resets the sweep clock.
    /// @param funder          Owner that supplied the USDC.
    /// @param usdcAmount      USDC pulled in, in 6-decimal raw units.
    /// @param sweepUnlockTime Timestamp from which the owner may sweep, set by this funding.
    event Funded(address indexed funder, uint256 usdcAmount, uint256 sweepUnlockTime);

    /// @notice Emitted when the owner sweeps remaining USDC after the timelock.
    /// @param to         Recipient of the swept USDC.
    /// @param usdcAmount USDC swept, in 6-decimal raw units.
    event Swept(address indexed to, uint256 usdcAmount);

    /// @notice Emitted when the owner rescues a stray (non-USDC) token.
    /// @param token  The rescued ERC-20.
    /// @param to     Recipient of the rescued balance.
    /// @param amount Amount transferred out, in the token's own units.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted once at deployment, capturing the immutable configuration.
    /// @param usdr  USDR token address.
    /// @param usdc  USDC token address.
    /// @param rate  USDC raw units per whole USDR.
    /// @param owner Initial owner.
    event Deployed(address indexed usdr, address indexed usdc, uint256 rate, address indexed owner);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @dev A required address argument was the zero address.
    error ZeroAddress();
    /// @dev A required amount argument was zero.
    error ZeroAmount();
    /// @dev The configured rate was zero.
    error ZeroRate();
    /// @dev The USDR and USDC addresses must differ.
    error IdenticalTokens();
    /// @dev USDR must report 9 decimals and USDC 6, matching USDR_UNIT and the rate's units.
    error UnexpectedDecimals();
    /// @dev The redemption would pay out zero USDC — the amount (zero included) is too small
    ///      for the rate to yield a non-zero payout.
    error ZeroPayout();
    /// @dev The contract's USDC balance cannot cover the full payout.
    error InsufficientUSDC(uint256 required, uint256 available);
    /// @dev Sweep attempted before the timelock expired; unlocked at `unlockTime`.
    error SweepLocked(uint256 unlockTime);
    /// @dev USDC can only leave via redeem or the timelocked sweep, never via rescue.
    error CannotRescueUSDC();

    // ---------------------------------------------------------------------
    // Config (immutables & constants)
    // ---------------------------------------------------------------------

    /// @notice One whole USDR in raw units (USDR has 9 decimals).
    function USDR_UNIT() external view returns (uint256);

    /// @notice Time after the last funding before the owner may sweep USDC ("6 months").
    function SWEEP_DELAY() external view returns (uint256);

    /// @notice The USDR token (9 decimals); burned from redeemers via allowance.
    function usdr() external view returns (IUSDR);

    /// @notice The USDC token paid out (6 decimals); native USDC, fixed at deploy.
    function usdc() external view returns (IERC20);

    /// @notice Redemption rate in USDC raw units (6 decimals) per 1 whole USDR.
    function rate() external view returns (uint256);

    /// @notice Timestamp of the most recent {fund} call (deployment time before any).
    function lastFundingTime() external view returns (uint256);

    // ---------------------------------------------------------------------
    // Redemption
    // ---------------------------------------------------------------------

    /// @notice Redeems `usdrAmount` USDR for USDC at the fixed rate, paying msg.sender.
    /// @param  usdrAmount Amount of USDR to redeem, in 9-decimal raw units.
    /// @return usdcAmount USDC paid out, in 6-decimal raw units.
    function redeem(uint256 usdrAmount) external returns (uint256 usdcAmount);

    /// @notice Redeems `usdrAmount` USDR for USDC at the fixed rate, paying `receiver`.
    /// @param  usdrAmount Amount of USDR to redeem, in 9-decimal raw units.
    /// @param  receiver   USDC recipient; address(0) is treated as msg.sender.
    /// @return usdcAmount USDC paid out, in 6-decimal raw units.
    function redeem(uint256 usdrAmount, address receiver) external returns (uint256 usdcAmount);

    // ---------------------------------------------------------------------
    // Funding & wind-down (owner)
    // ---------------------------------------------------------------------

    /// @notice Pulls `usdcAmount` USDC from the owner into the contract and resets the
    ///         6-month sweep clock.
    /// @param  usdcAmount USDC to pull in, in 6-decimal raw units.
    function fund(uint256 usdcAmount) external;

    /// @notice Sweeps the contract's entire USDC balance to `to` after the timelock.
    /// @param  to Recipient of the swept USDC.
    function sweep(address to) external;

    /// @notice Recovers the full balance of a stray (non-USDC) ERC-20 sent here.
    /// @param  token The ERC-20 to rescue (USDC is rejected).
    /// @param  to    Recipient of the rescued balance.
    function rescueERC20(address token, address to) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice USDC payout for `usdrAmount` USDR at the fixed rate, rounded down.
    /// @param  usdrAmount Amount of USDR, in 9-decimal raw units.
    /// @return The USDC payout, in 6-decimal raw units.
    function previewRedeem(uint256 usdrAmount) external view returns (uint256);

    /// @notice USDC currently available to pay redemptions (the live balance).
    /// @return The contract's USDC balance, in 6-decimal raw units.
    function availableUSDC() external view returns (uint256);

    /// @notice Largest USDR amount guaranteed to redeem without reverting right now.
    /// @return The largest non-reverting USDR amount, or 0 if none is possible.
    function maxRedeemableUSDR() external view returns (uint256);

    /// @notice Earliest timestamp at which the owner may sweep remaining USDC.
    /// @return The timestamp `lastFundingTime + SWEEP_DELAY`.
    function sweepUnlockTime() external view returns (uint256);
}
