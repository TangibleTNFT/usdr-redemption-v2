// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IUSDR} from "./interfaces/IUSDR.sol";

/// @title USDR Redemption v2
/// @notice Atomic, stateless, fixed-rate, first-come-first-served USDR -> USDC swap.
///
///         A holder grants this contract a USDR allowance and calls {redeem}. In one
///         transaction the contract burns the USDR directly from the holder (it never
///         custodies USDR) and pays out USDC at the immutable fixed rate, from the USDC
///         it currently holds only. If the contract's USDC balance cannot cover the full
///         payout, the call reverts — no queue, no IOUs, no per-user state.
///
///         Tangible tops up USDC over time via {fund} (owner-only). Once 6 months
///         (180 days) pass with no funding, the owner may {sweep} the remaining USDC.
///         Every funding resets that clock.
///
///         Spec invariants:
///         - I1  never transfers out more USDC than held; full payout or revert.
///         - I2  USDC is paid only for USDR burned at the fixed rate, same transaction.
///         - I3  the rate is immutable.
///         - I4  no per-user or time-indexed accounting; user gas is O(1).
///         - I5  the owner cannot withdraw USDC until 180 days after the last funding.
///
/// @dev    fund() is owner-only so the sweep clock can never be reset (griefed) by
///         third-party dust deposits. Raw USDC transfers to this contract are still
///         possible but do not touch the clock — they simply increase the redeemable
///         (and eventually sweepable) balance. `lastFundingTime` is initialized to the
///         deployment timestamp so the timelock also covers any USDC received before
///         the first fund() call.
///
///         Reentrancy: neither token has transfer hooks and the contract keeps no
///         mutable accounting, but both tokens are upgradeable proxies, so a cheap
///         nonReentrant guard is kept on redeem as defense in depth. It uses the
///         transient-storage (EIP-1153) guard, which the Polygon PoS deployment target
///         supports; the build pins evm_version = cancun. The contract is deliberately
///         non-upgradeable.
contract USDRRedemption is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants & immutables
    // ---------------------------------------------------------------------

    /// @notice One whole USDR in raw units (USDR has 9 decimals).
    uint256 public constant USDR_UNIT = 1e9;

    /// @notice Time after the last funding before the owner may sweep USDC ("6 months").
    uint256 public constant SWEEP_DELAY = 180 days;

    /// @notice The USDR token (9 decimals); burned from redeemers via allowance.
    IUSDR public immutable usdr;

    /// @notice The USDC token paid out (6 decimals); native USDC or USDC.e, fixed at deploy.
    IERC20 public immutable usdc;

    /// @notice Redemption rate in USDC raw units (6 decimals) per 1 whole USDR.
    /// @dev    e.g. $0.54 -> 540_000; $0.5417 -> 541_700. Precision is $0.000001.
    ///         Payout = usdrAmount * rate / 1e9, rounded down.
    uint256 public immutable rate;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Timestamp of the most recent {fund} call (deployment time before any).
    ///         The owner may sweep USDC from `lastFundingTime + SWEEP_DELAY` onward.
    uint256 public lastFundingTime;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    /// @notice Emitted on every successful redemption.
    event Redeemed(address indexed redeemer, address indexed receiver, uint256 usdrAmount, uint256 usdcAmount);

    /// @notice Emitted on every funding; each one resets the sweep clock.
    event Funded(address indexed funder, uint256 usdcAmount);

    /// @notice Emitted when the owner sweeps remaining USDC after the timelock.
    event Swept(address indexed to, uint256 usdcAmount);

    /// @notice Emitted when the owner rescues a stray (non-USDC) token.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted once at deployment, capturing the immutable configuration.
    event Deployed(address indexed usdr, address indexed usdc, uint256 rate, address indexed owner);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroRate();
    /// @dev The USDR and USDC addresses must differ.
    error IdenticalTokens();
    /// @dev USDR must report 9 decimals and USDC 6, matching USDR_UNIT and the rate's units.
    error UnexpectedDecimals();
    /// @dev The redemption would pay out zero USDC (amount too small for the rate).
    error ZeroPayout();
    /// @dev The contract's USDC balance cannot cover the full payout.
    error InsufficientUSDC(uint256 required, uint256 available);
    /// @dev Sweep attempted before the timelock expired; unlocked at `unlockTime`.
    error SweepLocked(uint256 unlockTime);
    /// @dev USDC can only leave via redeem or the timelocked sweep, never via rescue.
    error CannotRescueUSDC();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param usdr_  USDR token address (constructor arg for testability;
    ///               0x40379a439D4F6795B6fc9aa5687dB461677A2dBa on Polygon).
    /// @param usdc_  USDC token address (native USDC or USDC.e, decided at deploy).
    /// @param rate_  USDC raw units per whole USDR (e.g. 541_700 for $0.5417).
    /// @param owner_ Contract owner — a Gnosis Safe multisig in production.
    constructor(address usdr_, address usdc_, uint256 rate_, address owner_) Ownable(owner_) {
        if (usdr_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        if (usdr_ == usdc_) revert IdenticalTokens();
        if (rate_ == 0) revert ZeroRate();
        // Self-check the decimal assumptions baked into USDR_UNIT (1e9) and the 6-decimal
        // rate, so a misconfigured token deployment fails fast instead of mispricing payouts.
        if (IERC20Metadata(usdr_).decimals() != 9 || IERC20Metadata(usdc_).decimals() != 6) {
            revert UnexpectedDecimals();
        }
        usdr = IUSDR(usdr_);
        usdc = IERC20(usdc_);
        rate = rate_;
        lastFundingTime = block.timestamp;
        emit Deployed(usdr_, usdc_, rate_, owner_);
    }

    // ---------------------------------------------------------------------
    // Redemption
    // ---------------------------------------------------------------------

    /// @notice Redeems `usdrAmount` USDR for USDC at the fixed rate, paying msg.sender.
    function redeem(uint256 usdrAmount) external returns (uint256) {
        return _redeem(usdrAmount, msg.sender);
    }

    /// @notice Redeems `usdrAmount` USDR for USDC at the fixed rate, paying `receiver`.
    /// @dev    Requires a prior USDR approval of at least `usdrAmount` to this contract.
    ///         All-or-nothing: reverts unless the full payout can be made.
    /// @param  usdrAmount Amount of USDR to redeem, in 9-decimal raw units.
    /// @param  receiver   USDC recipient; address(0) is treated as msg.sender.
    /// @return usdcAmount USDC paid out, in 6-decimal raw units.
    function redeem(uint256 usdrAmount, address receiver) external returns (uint256) {
        return _redeem(usdrAmount, receiver == address(0) ? msg.sender : receiver);
    }

    function _redeem(uint256 usdrAmount, address receiver) internal nonReentrant returns (uint256 usdcAmount) {
        usdcAmount = previewRedeem(usdrAmount);
        if (usdcAmount == 0) revert ZeroPayout();

        uint256 available = usdc.balanceOf(address(this));
        if (usdcAmount > available) revert InsufficientUSDC(usdcAmount, available);

        // Burn USDR straight from the redeemer (allowance-based; never custodied here),
        // then pay USDC — both external calls after all checks.
        usdr.burn(msg.sender, usdrAmount);
        usdc.safeTransfer(receiver, usdcAmount);

        emit Redeemed(msg.sender, receiver, usdrAmount, usdcAmount);
    }

    // ---------------------------------------------------------------------
    // Funding & wind-down (owner)
    // ---------------------------------------------------------------------

    /// @notice Pulls `usdcAmount` USDC from the owner into the contract and resets the
    ///         6-month sweep clock. Owner-only so dust deposits can't grief the clock.
    /// @dev    The owner must have approved this contract for `usdcAmount` USDC first.
    function fund(uint256 usdcAmount) external onlyOwner {
        if (usdcAmount == 0) revert ZeroAmount();
        lastFundingTime = block.timestamp;
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        emit Funded(msg.sender, usdcAmount);
    }

    /// @notice Sweeps the contract's entire USDC balance to `to`. Only callable by the
    ///         owner once 180 days have passed since the last funding (or deployment,
    ///         if never funded).
    function sweep(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        // `lastFundingTime` is a block timestamp (< 2^32 for centuries) and SWEEP_DELAY is
        // a 180-day constant, so the sum cannot overflow uint256 — skip the checked-add guard.
        uint256 unlockTime;
        unchecked {
            unlockTime = lastFundingTime + SWEEP_DELAY;
        }
        if (block.timestamp < unlockTime) revert SweepLocked(unlockTime);
        uint256 balance = usdc.balanceOf(address(this));
        usdc.safeTransfer(to, balance);
        emit Swept(to, balance);
    }

    /// @notice Recovers the full balance of a stray ERC-20 accidentally sent here.
    /// @dev    USDC is explicitly excluded so this can never bypass the sweep timelock
    ///         (I5). USDR is never held by this contract (burned straight from holders),
    ///         so any USDR balance is itself a stray transfer and is recoverable.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(usdc)) revert CannotRescueUSDC();
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
        emit Rescued(token, to, balance);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice USDC payout for `usdrAmount` USDR at the fixed rate, rounded down.
    function previewRedeem(uint256 usdrAmount) public view returns (uint256) {
        return (usdrAmount * rate) / USDR_UNIT;
    }

    /// @notice USDC currently available to pay redemptions (the live balance).
    function availableUSDC() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Largest USDR amount guaranteed to redeem without reverting right now.
    /// @dev    Rounded down, so redeeming exactly this amount always pays out within the
    ///         available balance. Intended for UIs sizing a redeem (spec R3); it is a
    ///         conservative bound and can change with every block (FCFS race).
    ///
    ///         At a dust balance the inverse-rounded amount can still preview to a zero
    ///         payout (e.g. 1 raw USDC unit -> 1846 USDR, which {previewRedeem}s to 0 and
    ///         would revert with {ZeroPayout}). In that case this returns 0 rather than
    ///         advertising an amount that {redeem} would reject.
    /// @return m The largest USDR amount whose {previewRedeem} is non-zero and fits within
    ///           the available USDC, or 0 when no non-reverting redemption is possible.
    function maxRedeemableUSDR() external view returns (uint256 m) {
        m = (availableUSDC() * USDR_UNIT) / rate;
        if (previewRedeem(m) == 0) return 0; // never advertise an amount that would revert
    }

    /// @notice Earliest timestamp at which the owner may sweep remaining USDC.
    /// @return The timestamp `lastFundingTime + SWEEP_DELAY` (cannot overflow; see {sweep}).
    function sweepUnlockTime() external view returns (uint256) {
        // See {sweep}: a block timestamp plus a 180-day constant cannot overflow uint256.
        unchecked {
            return lastFundingTime + SWEEP_DELAY;
        }
    }
}
