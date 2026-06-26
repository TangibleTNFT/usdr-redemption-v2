// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IUSDR} from "./interfaces/IUSDR.sol";
import {IUSDRRedemption} from "./interfaces/IUSDRRedemption.sol";

/// @title USDR Redemption v2
/// @notice Atomic, fixed-rate, first-come-first-served USDR -> USDC swap with no per-user
///         state (the only mutable storage is the global `lastFundingTime` sweep clock).
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
contract USDRRedemption is Ownable2Step, ReentrancyGuardTransient, IUSDRRedemption {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants & immutables
    // ---------------------------------------------------------------------

    /// @inheritdoc IUSDRRedemption
    uint256 public constant override USDR_UNIT = 1e9;

    /// @inheritdoc IUSDRRedemption
    uint256 public constant override SWEEP_DELAY = 180 days;

    /// @inheritdoc IUSDRRedemption
    IUSDR public immutable override usdr;

    /// @inheritdoc IUSDRRedemption
    IERC20 public immutable override usdc;

    /// @inheritdoc IUSDRRedemption
    /// @dev Deploy value $0.532 -> 532_000 (e.g. $0.5417 -> 541_700). Precision is $0.000001.
    ///      Payout = usdrAmount * rate / 1e9, rounded down.
    uint256 public immutable override rate;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @inheritdoc IUSDRRedemption
    /// @dev The owner may sweep USDC from `lastFundingTime + SWEEP_DELAY` onward.
    uint256 public override lastFundingTime;

    // Events and errors are declared in {IUSDRRedemption}.

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param usdr_  USDR token address (constructor arg for testability;
    ///               0x40379a439D4F6795B6fc9aa5687dB461677A2dBa on Polygon).
    /// @param usdc_  USDC token address (native USDC 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 on Polygon).
    /// @param rate_  USDC raw units per whole USDR (532_000 for $0.532, the deploy value).
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

    /// @inheritdoc IUSDRRedemption
    function redeem(uint256 usdrAmount) external override returns (uint256) {
        return _redeem(usdrAmount, msg.sender);
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev Requires a prior USDR approval of at least `usdrAmount` to this contract.
    ///      All-or-nothing: reverts unless the full payout can be made.
    function redeem(uint256 usdrAmount, address receiver) external override returns (uint256) {
        return _redeem(usdrAmount, receiver == address(0) ? msg.sender : receiver);
    }

    function _redeem(uint256 usdrAmount, address receiver) internal nonReentrant returns (uint256 usdcAmount) {
        usdcAmount = previewRedeem(usdrAmount);
        if (usdcAmount == 0) revert ZeroPayout();

        uint256 available = availableUSDC();
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

    /// @inheritdoc IUSDRRedemption
    /// @dev Owner-only so dust deposits can't grief the clock; the owner must have approved
    ///      this contract for `usdcAmount` USDC first.
    function fund(uint256 usdcAmount) external override onlyOwner nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        lastFundingTime = block.timestamp;
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 unlockTime;
        unchecked {
            unlockTime = block.timestamp + SWEEP_DELAY; // see {sweep}: cannot overflow
        }
        emit Funded(msg.sender, usdcAmount, unlockTime);
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev Callable by the owner once 180 days have passed since the last funding (or
    ///      deployment, if never funded). Unlike {redeem}, `to` is not zero-coerced — a
    ///      zero address reverts rather than defaulting to msg.sender.
    function sweep(address to) external override onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        // `lastFundingTime` is a block timestamp (< 2^32 for centuries) and SWEEP_DELAY is
        // a 180-day constant, so the sum cannot overflow uint256 — skip the checked-add guard.
        uint256 unlockTime;
        unchecked {
            unlockTime = lastFundingTime + SWEEP_DELAY;
        }
        if (block.timestamp < unlockTime) revert SweepLocked(unlockTime);
        uint256 balance = availableUSDC();
        usdc.safeTransfer(to, balance);
        emit Swept(to, balance);
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev USDC is explicitly excluded so this can never bypass the sweep timelock (I5).
    ///      USDR is never held by this contract (burned straight from holders), so any USDR
    ///      balance is itself a stray transfer and is recoverable. The balance goes to `to`
    ///      (chosen by the owner, not necessarily the original sender); like {sweep}, `to`
    ///      is not zero-coerced.
    function rescueERC20(address token, address to) external override onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(usdc)) revert CannotRescueUSDC();
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
        emit Rescued(token, to, balance);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IUSDRRedemption
    /// @dev Kept `public` (not `external`): {_redeem} and {maxRedeemableUSDR} call it internally.
    function previewRedeem(uint256 usdrAmount) public view override returns (uint256) {
        return (usdrAmount * rate) / USDR_UNIT;
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev Kept `public` (not `external`): {_redeem}, {sweep} and {maxRedeemableUSDR} call it.
    function availableUSDC() public view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev Rounded down, so redeeming exactly this amount always pays out within the
    ///      available balance. Intended for UIs sizing a redeem (spec R3); a conservative
    ///      bound that can change with every block (FCFS race). At a dust balance the
    ///      inverse-rounded amount can preview to zero (e.g. 1 raw USDC unit -> 1846 USDR,
    ///      which {previewRedeem}s to 0 and would revert with {ZeroPayout}); this returns 0
    ///      rather than advertising an amount {redeem} would reject.
    /// @return m The largest USDR amount whose {previewRedeem} is non-zero and fits within
    ///           the available USDC, or 0 when no non-reverting redemption is possible.
    function maxRedeemableUSDR() external view override returns (uint256 m) {
        m = (availableUSDC() * USDR_UNIT) / rate;
        if (previewRedeem(m) == 0) return 0; // never advertise an amount that would revert
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev Cannot overflow; see {sweep}.
    function sweepUnlockTime() external view override returns (uint256) {
        // See {sweep}: a block timestamp plus a 180-day constant cannot overflow uint256.
        unchecked {
            return lastFundingTime + SWEEP_DELAY;
        }
    }
}
