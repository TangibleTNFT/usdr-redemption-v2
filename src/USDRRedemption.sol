// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IUSDR} from "./interfaces/IUSDR.sol";
import {IUSDRRedemption} from "./interfaces/IUSDRRedemption.sol";

/// @title USDR Redemption v2
/// @notice Pro-rata USDR -> USDC redemption. Every holder is entitled to exactly their share
///         of the USDC that has actually been funded, regardless of when they redeem.
///
///         The contract is deployed with the total USDR supply `S` that may ever be redeemed
///         (a deploy parameter, not the token's on-chain `totalSupply()`) and a target rate
///         `R` in USDC per USDR. Tangible funds USDC over time via {fund}, up to
///         `expectedFunding = ceil(S * R / 1e9)`. A holder presenting `x` USDR has their USDR
///         burned and is registered for `x` shares; a position with `shares` is entitled to
///
///             entitled = shares * totalFunded / S      (rounded down)
///
///         and is paid `entitled - paid` on every {redeem} or {claim}. The rate cancels out
///         of that formula — it only fixes where "fully funded" sits. This makes the
///         accounting order- and timing-independent (see "Rounding" below).
///
///         The owner may raise the rate ({setRate}), never lower it. Raising it increases
///         {expectedFunding}; once the extra USDC is funded every position, including ones
///         that already redeemed, is owed more and can {claim} it.
///
///         Wind-down: 180 days after the contract becomes fully funded the owner may {sweep}
///         the entire balance, which permanently closes the contract. That is the single
///         deadline for everyone — holders who never presented their USDR and holders who
///         presented it but never claimed the remainder alike. If full funding is never
///         reached, no sweep is ever possible.
///
///         Rounding (all divisions floor; `S`, `F = totalFunded`, `s = shares`):
///         - Path independence: payouts telescope, so a position receives exactly
///           `floor(s * F_final / S)` in total whether it claims after every funding or once.
///         - Tranche independence: presenting `x1` then `x2` ends at the same `paid` as
///           presenting `x1 + x2` once, since entitlement is linear and `paid` is always
///           reset to the current floor.
///         - Order independence: entitlement depends only on `(s, F)`, never on who went first.
///         - Wallet splitting can lose at most 1 raw unit per extra wallet and never gains.
///         - Solvency: `sum(s) <= S` and flooring give `sum(entitled) <= F`, hence
///           `balance >= F - totalPaid >= sum(owed)`. Floor dust stays in the contract until
///           the terminal sweep.
///         - {expectedFunding} rounds up so that at full funding no holder receives less than
///           `floor(s * R / 1e9)`; the owner over-funds by strictly less than one raw unit.
///
///         Invariants:
///         - I1  solvency: `usdc.balanceOf(this) >= totalFunded - totalPaid` while open.
///         - I2  pro-rata: `paid <= floor(shares * totalFunded / S)` for every position, with
///               equality immediately after each settlement.
///         - I3  the rate only ever increases.
///         - I4  user gas is O(1): exactly one storage slot per redeemer, no history replay.
///         - I5  the owner cannot withdraw USDC before 180 days after full funding.
///         - I6  `totalFunded <= expectedFunding` and `totalShares <= S`.
///         - I7  the first sweep closes the contract for good.
///
/// @dev    Overflow bounds: the constructor requires `S <= type(uint128).max`, and both the
///         constructor and {setRate} require `expectedFunding <= type(uint128).max`
///         ({ConfigOverflow}). Hence `shares <= S` and `paid <= entitled <= F <= expectedFunding`
///         provably fit the packed uint128 fields of {Position}, and every product formed
///         here is computed with {Math.mulDiv} (512-bit intermediate) anyway.
///
///         USDC received through raw transfers is not funding automatically: it does not move
///         `totalFunded` or become owed to anyone until the owner deliberately recognizes it
///         through {fundFromBalance}. Otherwise it only leaves through {sweep}.
///
///         Reentrancy: neither token has transfer hooks, but both are upgradeable proxies, so
///         a transient-storage (EIP-1153) nonReentrant guard is kept on every path that
///         interacts with an external token as defense in depth; the build pins evm_version =
///         cancun, which the Polygon PoS target supports. Accounting state is written before
///         any external token call (CEI).
///         The contract is deliberately non-upgradeable.
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
    /// @dev Deploy value 35_909_552 USDR -> 35_909_552e9 raw. Bounded to uint128 by the constructor.
    uint256 public immutable override totalUSDRSupply;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @inheritdoc IUSDRRedemption
    /// @dev Deploy value $0.532 -> 532_000 (e.g. $0.5417 -> 541_700). Precision is $0.000001.
    uint256 public override rate;

    /// @inheritdoc IUSDRRedemption
    uint256 public override totalFunded;

    /// @inheritdoc IUSDRRedemption
    uint256 public override totalShares;

    /// @inheritdoc IUSDRRedemption
    uint256 public override totalPaid;

    /// @inheritdoc IUSDRRedemption
    uint256 public override fullyFundedAt;

    /// @inheritdoc IUSDRRedemption
    bool public override closed;

    /// @inheritdoc IUSDRRedemption
    mapping(address account => Position) public override positions;

    // Events and errors are declared in {IUSDRRedemption}.

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier whenOpen() {
        if (closed) revert ContractClosed();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param usdr_        USDR token address (constructor arg for testability;
    ///                     0x40379a439D4F6795B6fc9aa5687dB461677A2dBa on Polygon).
    /// @param usdc_        USDC token address (native USDC 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 on Polygon).
    /// @param rate_        Initial USDC raw units per whole USDR (532_000 for $0.532, the deploy value).
    /// @param totalSupply_ USDR supply the pro-rata split is computed against, in 9-decimal raw
    ///                     units (35_909_552e9 for the deploy). Immutable.
    /// @param owner_       Contract owner — a Gnosis Safe multisig in production.
    constructor(address usdr_, address usdc_, uint256 rate_, uint256 totalSupply_, address owner_) Ownable(owner_) {
        if (usdr_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        if (usdr_ == usdc_) revert IdenticalTokens();
        if (rate_ == 0) revert ZeroRate();
        if (totalSupply_ == 0) revert ZeroTotalSupply();
        // Bound the packed Position fields (see the contract-level @dev).
        if (totalSupply_ > type(uint128).max) revert ConfigOverflow();
        if (_expectedFunding(totalSupply_, rate_) > type(uint128).max) revert ConfigOverflow();

        // Commit constructor state before querying the external token contracts. Any failed
        // metadata check still reverts creation and all of these assignments atomically.
        usdr = IUSDR(usdr_);
        usdc = IERC20(usdc_);
        rate = rate_;
        totalUSDRSupply = totalSupply_;

        // Self-check the decimal assumptions baked into USDR_UNIT (1e9) and the 6-decimal
        // rate, so a misconfigured token deployment fails fast instead of mispricing payouts.
        if (IERC20Metadata(usdr_).decimals() != 9 || IERC20Metadata(usdc_).decimals() != 6) {
            revert UnexpectedDecimals();
        }
        emit Deployed(usdr_, usdc_, rate_, totalSupply_, owner_);
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
    function redeem(uint256 usdrAmount, address receiver) external override returns (uint256) {
        return _redeem(usdrAmount, receiver == address(0) ? msg.sender : receiver);
    }

    /// @inheritdoc IUSDRRedemption
    function claim() external override returns (uint256) {
        return _claim(msg.sender);
    }

    /// @inheritdoc IUSDRRedemption
    function claim(address receiver) external override returns (uint256) {
        return _claim(receiver == address(0) ? msg.sender : receiver);
    }

    function _redeem(uint256 usdrAmount, address receiver) internal nonReentrant whenOpen returns (uint256 usdcAmount) {
        if (usdrAmount == 0) revert ZeroAmount();
        uint256 remaining = totalUSDRSupply - totalShares;
        if (usdrAmount > remaining) revert ShareCapExceeded(usdrAmount, remaining);

        Position storage p = positions[msg.sender];
        // casting to 'uint128' is safe because
        // `p.shares + usdrAmount <= totalShares + usdrAmount <= totalUSDRSupply <= uint128.max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        p.shares = uint128(p.shares + usdrAmount);
        totalShares += usdrAmount;
        usdcAmount = _settle(p);

        // Burn USDR straight from the redeemer (allowance-based; never custodied here),
        // then pay USDC — both external calls after all state writes.
        usdr.burn(msg.sender, usdrAmount);
        if (usdcAmount != 0) usdc.safeTransfer(receiver, usdcAmount);

        emit Redeemed(msg.sender, receiver, usdrAmount, usdcAmount);
    }

    function _claim(address receiver) internal nonReentrant whenOpen returns (uint256 usdcAmount) {
        usdcAmount = _settle(positions[msg.sender]);
        if (usdcAmount == 0) revert NothingToClaim();

        usdc.safeTransfer(receiver, usdcAmount);

        emit Claimed(msg.sender, receiver, usdcAmount);
    }

    /// @dev Brings `p.paid` up to the position's current entitlement and returns the
    ///      difference, which the caller pays out. Never underflows: `paid` was set to a
    ///      floor of the same expression at a time when both `shares` and `totalFunded` were
    ///      no larger than now.
    function _settle(Position storage p) internal returns (uint256 usdcAmount) {
        uint256 entitled = _entitled(p.shares);
        usdcAmount = entitled - p.paid;
        if (usdcAmount != 0) {
            // casting to 'uint128' is safe because
            // `entitled <= totalFunded <= expectedFunding <= uint128.max`.
            // forge-lint: disable-next-line(unsafe-typecast)
            p.paid = uint128(entitled);
            totalPaid += usdcAmount;
        }
    }

    // ---------------------------------------------------------------------
    // Funding & wind-down (owner)
    // ---------------------------------------------------------------------

    /// @inheritdoc IUSDRRedemption
    /// @dev The owner must have approved this contract for `usdcAmount` USDC first.
    function fund(uint256 usdcAmount) external override nonReentrant onlyOwner whenOpen {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 balanceBefore = availableUSDC();
        uint256 funded = _recordFunding(usdcAmount);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 balanceAfter = availableUSDC();
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != usdcAmount) revert FundingReceiptMismatch(usdcAmount, received);

        emit Funded(msg.sender, usdcAmount, funded);
    }

    /// @inheritdoc IUSDRRedemption
    function fundFromBalance(uint256 usdcAmount) external override nonReentrant onlyOwner whenOpen {
        if (usdcAmount == 0) revert ZeroAmount();

        uint256 remaining = expectedFunding() - totalFunded;
        if (usdcAmount > remaining) revert FundingExceedsExpected(usdcAmount, remaining);

        // The accounted reserve is exactly what prior funding still owes. Anything above it
        // arrived outside fund() and may safely be recognized without making the ledger
        // insolvent. Saturate at zero so a broken token cannot turn this diagnostic into an
        // arithmetic panic.
        uint256 accountedReserve = totalFunded - totalPaid;
        uint256 balance = availableUSDC();
        uint256 unaccounted = balance > accountedReserve ? balance - accountedReserve : 0;
        if (usdcAmount > unaccounted) revert InsufficientUnaccountedUSDC(usdcAmount, unaccounted);

        uint256 funded = _recordFunding(usdcAmount);
        emit ExistingFundingRecognized(msg.sender, usdcAmount, funded);
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev Clears {fullyFundedAt} unless the new {expectedFunding} is still met — which can
    ///      only happen when `totalUSDRSupply < USDR_UNIT`, where a small raise may not move
    ///      the ceiling — so `fullyFundedAt != 0` stays equivalent to "fully funded".
    function setRate(uint256 newRate) external override onlyOwner whenOpen {
        uint256 oldRate = rate;
        if (newRate <= oldRate) revert RateNotIncreasing(oldRate, newRate);
        uint256 expected = _expectedFunding(totalUSDRSupply, newRate);
        if (expected > type(uint128).max) revert ConfigOverflow();

        rate = newRate;
        if (totalFunded != expected) fullyFundedAt = 0;

        emit RateUpdated(oldRate, newRate);
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev Unlike {redeem}, `to` is not zero-coerced — a zero address reverts rather than
    ///      defaulting to msg.sender. Stays callable after closing: {fullyFundedAt} can no
    ///      longer change, so the timelock condition holds forever.
    function sweep(address to) external override nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 unlockTime = sweepUnlockTime();
        if (block.timestamp < unlockTime) revert SweepLocked(unlockTime);
        uint256 balance = availableUSDC();
        if (balance == 0 && closed) revert ZeroAmount();

        if (!closed) {
            closed = true;
            emit Closed();
        }

        if (balance != 0) usdc.safeTransfer(to, balance);
        emit Swept(to, balance);
    }

    /// @inheritdoc IUSDRRedemption
    /// @dev USDC is explicitly excluded so this can never bypass the sweep timelock (I5).
    ///      USDR is never held by this contract (burned straight from holders), so any USDR
    ///      balance is itself a stray transfer and is recoverable. The balance goes to `to`
    ///      (chosen by the owner, not necessarily the original sender); like {sweep}, `to`
    ///      is not zero-coerced and an empty balance reverts with {ZeroAmount} — which also
    ///      turns a mistyped or already-rescued token address into a clear failure instead
    ///      of a successful no-op.
    function rescueERC20(address token, address to) external override nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(usdc)) revert CannotRescueUSDC();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, balance);
        emit Rescued(token, to, balance);
    }

    /// @notice Disabled — ownership can only move via the two-step {transferOwnership}.
    /// @dev Renouncing would silently strip every owner-gated path: {fund} could no longer
    ///      bring the contract to full funding, {setRate} could never raise the rate, {sweep}
    ///      could never close the contract and recover the remainder, {rescueERC20} could
    ///      never free a stray token, and no owner could be reinstated. Ownable exposes this
    ///      as a single-step call with no confirmation, unlike the two-step handover, so it is
    ///      overridden to always revert.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IUSDRRedemption
    function expectedFunding() public view override returns (uint256) {
        return _expectedFunding(totalUSDRSupply, rate);
    }

    /// @inheritdoc IUSDRRedemption
    function remainingFunding() external view override returns (uint256) {
        return expectedFunding() - totalFunded;
    }

    /// @inheritdoc IUSDRRedemption
    function isFullyFunded() external view override returns (bool) {
        return fullyFundedAt != 0;
    }

    /// @inheritdoc IUSDRRedemption
    function effectiveRate() external view override returns (uint256) {
        return Math.mulDiv(rate, totalFunded, expectedFunding());
    }

    /// @inheritdoc IUSDRRedemption
    function previewRedeem(uint256 usdrAmount) external view override returns (uint256) {
        return closed ? 0 : _entitled(usdrAmount);
    }

    /// @inheritdoc IUSDRRedemption
    function previewRedeem(address account, uint256 usdrAmount) external view override returns (uint256) {
        if (closed) return 0;
        Position storage p = positions[account];
        return _entitled(p.shares + usdrAmount) - p.paid;
    }

    /// @inheritdoc IUSDRRedemption
    function claimableUSDC(address account) external view override returns (uint256) {
        if (closed) return 0;
        Position storage p = positions[account];
        return _entitled(p.shares) - p.paid;
    }

    /// @inheritdoc IUSDRRedemption
    function outstandingUSDC() external view override returns (uint256) {
        return closed ? 0 : _entitled(totalShares) - totalPaid;
    }

    /// @inheritdoc IUSDRRedemption
    function availableUSDC() public view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @inheritdoc IUSDRRedemption
    function maxRedeemableUSDR() external view override returns (uint256) {
        return closed ? 0 : totalUSDRSupply - totalShares;
    }

    /// @inheritdoc IUSDRRedemption
    function sweepUnlockTime() public view override returns (uint256) {
        uint256 t = fullyFundedAt;
        if (t == 0) return type(uint256).max;
        // A block timestamp plus a 180-day constant cannot overflow uint256.
        unchecked {
            return t + SWEEP_DELAY;
        }
    }

    // ---------------------------------------------------------------------
    // Internal math
    // ---------------------------------------------------------------------

    /// @dev The pro-rata entitlement of `shares` at the current funding level, rounded down.
    function _entitled(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, totalFunded, totalUSDRSupply);
    }

    /// @dev `ceil(totalSupply * rate_ / USDR_UNIT)`; see {IUSDRRedemption.expectedFunding}.
    function _expectedFunding(uint256 totalSupply, uint256 rate_) internal pure returns (uint256) {
        return Math.mulDiv(totalSupply, rate_, USDR_UNIT, Math.Rounding.Ceil);
    }

    /// @dev Adds verified or already-present USDC to the pro-rata ledger and arms the sweep
    ///      clock when the funding target is reached. The caller is responsible for verifying
    ///      the source of the corresponding balance before this helper returns successfully.
    function _recordFunding(uint256 usdcAmount) internal returns (uint256 funded) {
        uint256 expected = expectedFunding();
        uint256 remaining = expected - totalFunded;
        if (usdcAmount > remaining) revert FundingExceedsExpected(usdcAmount, remaining);

        funded = totalFunded + usdcAmount;
        totalFunded = funded;
        if (funded == expected) {
            fullyFundedAt = block.timestamp;
            emit FullyFunded(block.timestamp + SWEEP_DELAY);
        }
    }
}
