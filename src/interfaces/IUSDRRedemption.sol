// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUSDR} from "./IUSDR.sol";

/// @title IUSDRRedemption
/// @notice External interface for the USDR Redemption v2 contract — the full public API,
///         events, and errors an integrator needs to interact with and index a deployment.
interface IUSDRRedemption {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice A redeemer's registered claim on the funded USDC.
    /// @dev Packed into a single storage slot. Both fields are provably bounded: `shares`
    ///      by `totalUSDRSupply` and `paid` by `expectedFunding`, and the constructor and
    ///      {setRate} both require those bounds to fit uint128 ({ConfigOverflow}).
    /// @param shares USDR presented (burned) by this account, in 9-decimal raw units.
    /// @param paid   USDC already paid out against those shares, in 6-decimal raw units.
    ///               Equals `shares * totalFunded / totalUSDRSupply` (floor) as of the
    ///               account's last settlement.
    struct Position {
        uint128 shares;
        uint128 paid;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when USDR is presented for redemption: the USDR is burned, the shares
    ///         are registered to the redeemer, and whatever they are owed so far is paid.
    /// @param redeemer   Holder whose USDR was burned and who owns the shares (msg.sender).
    /// @param receiver   Address the USDC was paid to.
    /// @param usdrAmount USDR burned, in 9-decimal raw units.
    /// @param usdcAmount USDC paid out in this call, in 6-decimal raw units. Zero when funding
    ///                   has not yet caught up; the shares remain claimable via {claim}.
    event Redeemed(address indexed redeemer, address indexed receiver, uint256 usdrAmount, uint256 usdcAmount);

    /// @notice Emitted when an existing position is settled against funding that arrived
    ///         since its last settlement.
    /// @param account    Owner of the position (msg.sender).
    /// @param receiver   Address the USDC was paid to.
    /// @param usdcAmount USDC paid out, in 6-decimal raw units.
    event Claimed(address indexed account, address indexed receiver, uint256 usdcAmount);

    /// @notice Emitted on every funding.
    /// @param funder      Owner that supplied the USDC.
    /// @param usdcAmount  USDC pulled in, in 6-decimal raw units.
    /// @param totalFunded Cumulative USDC funded after this call.
    event Funded(address indexed funder, uint256 usdcAmount, uint256 totalFunded);

    /// @notice Emitted when the owner recognizes USDC already held by the contract as funding.
    /// @param owner       Owner that classified the existing balance.
    /// @param usdcAmount  Existing USDC added to the pro-rata ledger.
    /// @param totalFunded Cumulative recognized funding after this call.
    event ExistingFundingRecognized(address indexed owner, uint256 usdcAmount, uint256 totalFunded);

    /// @notice Emitted when a funding brings {totalFunded} up to {expectedFunding}, which
    ///         starts the 180-day countdown to the terminal sweep.
    /// @param sweepUnlockTime Timestamp from which the owner may sweep.
    event FullyFunded(uint256 sweepUnlockTime);

    /// @notice Emitted when the owner raises the redemption rate.
    /// @param oldRate Previous rate, in USDC raw units per whole USDR.
    /// @param newRate New rate; strictly greater than `oldRate`.
    event RateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted once, by the first {sweep}, when the contract is permanently closed.
    event Closed();

    /// @notice Emitted when the owner sweeps the contract's USDC after the timelock.
    /// @param to         Recipient of the swept USDC.
    /// @param usdcAmount USDC swept, in 6-decimal raw units.
    event Swept(address indexed to, uint256 usdcAmount);

    /// @notice Emitted when the owner rescues a stray (non-USDC) token.
    /// @param token  The rescued ERC-20.
    /// @param to     Recipient of the rescued balance.
    /// @param amount Amount transferred out, in the token's own units.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted once at deployment, capturing the initial configuration.
    /// @param usdr        USDR token address.
    /// @param usdc        USDC token address.
    /// @param rate        Initial USDC raw units per whole USDR (owner-raisable, see {setRate}).
    /// @param totalSupply The immutable USDR supply the pro-rata split is computed against.
    /// @param owner       Initial owner.
    event Deployed(
        address indexed usdr, address indexed usdc, uint256 rate, uint256 totalSupply, address indexed owner
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @dev A required address argument was the zero address.
    error ZeroAddress();
    /// @dev A required amount argument was zero.
    error ZeroAmount();
    /// @dev The configured rate was zero.
    error ZeroRate();
    /// @dev The configured USDR total supply was zero.
    error ZeroTotalSupply();
    /// @dev The USDR and USDC addresses must differ.
    error IdenticalTokens();
    /// @dev USDR must report 9 decimals and USDC 6, matching USDR_UNIT and the rate's units.
    error UnexpectedDecimals();
    /// @dev `totalUSDRSupply` or the resulting {expectedFunding} does not fit the uint128
    ///      fields of {Position}. Raised by the constructor and by {setRate}.
    error ConfigOverflow();
    /// @dev The rate may only ever be raised; `proposed` was not greater than `current`.
    error RateNotIncreasing(uint256 current, uint256 proposed);
    /// @dev Funding beyond {expectedFunding} is rejected; `remaining` is the exact amount
    ///      that would top the contract up to full funding (see {remainingFunding}).
    error FundingExceedsExpected(uint256 requested, uint256 remaining);
    /// @dev {fund} received a different balance delta than requested. Production native USDC
    ///      should always transfer exactly; this protects the solvency ledger from incompatible
    ///      or changed token behavior.
    error FundingReceiptMismatch(uint256 requested, uint256 received);
    /// @dev {fundFromBalance} requested more than the unaccounted USDC already held.
    error InsufficientUnaccountedUSDC(uint256 requested, uint256 available);
    /// @dev Registering these shares would push {totalShares} past {totalUSDRSupply}, which
    ///      the pro-rata split assumes is the entire redeemable population.
    error ShareCapExceeded(uint256 requested, uint256 remaining);
    /// @dev The caller's position is owed nothing at the current funding level.
    error NothingToClaim();
    /// @dev Sweep attempted before the timelock expired; unlocked at `unlockTime`
    ///      (`type(uint256).max` while the contract is not yet fully funded).
    error SweepLocked(uint256 unlockTime);
    /// @dev The contract has been closed by a {sweep}; no further redemptions, claims,
    ///      funding or rate changes are possible.
    error ContractClosed();
    /// @dev USDC can only leave via redeem/claim or the timelocked sweep, never via rescue.
    error CannotRescueUSDC();
    /// @dev Ownership cannot be renounced; it would permanently disable {fund}, {setRate},
    ///      {sweep} and {rescueERC20}. Use the two-step {transferOwnership} instead.
    error RenounceOwnershipDisabled();

    // ---------------------------------------------------------------------
    // Config (immutables & constants)
    // ---------------------------------------------------------------------

    /// @notice One whole USDR in raw units (USDR has 9 decimals).
    function USDR_UNIT() external view returns (uint256);

    /// @notice Time after full funding before the owner may sweep ("6 months").
    function SWEEP_DELAY() external view returns (uint256);

    /// @notice The USDR token (9 decimals); burned from redeemers via allowance.
    function usdr() external view returns (IUSDR);

    /// @notice The USDC token paid out (6 decimals); native USDC, fixed at deploy.
    function usdc() external view returns (IERC20);

    /// @notice The USDR supply the pro-rata split is computed against, in 9-decimal raw units.
    /// @dev Supplied at deployment and immutable. Deliberately NOT the token's on-chain
    ///      `totalSupply()`: it is the agreed population of USDR that may ever be redeemed,
    ///      and {totalShares} can never exceed it.
    function totalUSDRSupply() external view returns (uint256);

    /// @notice Target redemption rate in USDC raw units (6 decimals) per 1 whole USDR.
    /// @dev Monotonic: the owner may only ever raise it ({setRate}). The rate does not appear
    ///      in the payout formula; it defines {expectedFunding} — where "fully funded" sits —
    ///      and therefore what a share is ultimately worth.
    function rate() external view returns (uint256);

    // ---------------------------------------------------------------------
    // Accounting state
    // ---------------------------------------------------------------------

    /// @notice Cumulative USDC recognized via {fund} or {fundFromBalance}.
    ///         Never exceeds {expectedFunding}.
    function totalFunded() external view returns (uint256);

    /// @notice Total USDR ever presented for redemption. Never exceeds {totalUSDRSupply}.
    function totalShares() external view returns (uint256);

    /// @notice Cumulative USDC paid out to redeemers. Never exceeds {totalFunded}.
    function totalPaid() external view returns (uint256);

    /// @notice Timestamp at which {totalFunded} reached {expectedFunding}; 0 while it has not.
    /// @dev Reset to 0 by {setRate}, which raises {expectedFunding} above {totalFunded}.
    function fullyFundedAt() external view returns (uint256);

    /// @notice True once the contract has been permanently closed by a {sweep}.
    function closed() external view returns (bool);

    /// @notice The registered position of `account`.
    function positions(address account) external view returns (uint128 shares, uint128 paid);

    // ---------------------------------------------------------------------
    // Redemption
    // ---------------------------------------------------------------------

    /// @notice Burns `usdrAmount` USDR from msg.sender, registers it as shares, and pays out
    ///         everything those shares are owed at the current funding level. Pays msg.sender.
    /// @dev    A zero payout (funding not yet caught up) is allowed and does not revert; the
    ///         shares stay claimable through {claim}. Reverts with {ShareCapExceeded} if the
    ///         amount would push {totalShares} past {totalUSDRSupply}.
    /// @param  usdrAmount Amount of USDR to present, in 9-decimal raw units.
    /// @return usdcAmount USDC paid out in this call, in 6-decimal raw units.
    function redeem(uint256 usdrAmount) external returns (uint256 usdcAmount);

    /// @notice Same as {redeem}, paying the USDC to `receiver`.
    /// @dev    The shares are always credited to msg.sender; only the USDC goes to `receiver`.
    /// @param  usdrAmount Amount of USDR to present, in 9-decimal raw units.
    /// @param  receiver   USDC recipient; address(0) is treated as msg.sender.
    /// @return usdcAmount USDC paid out in this call, in 6-decimal raw units.
    function redeem(uint256 usdrAmount, address receiver) external returns (uint256 usdcAmount);

    /// @notice Settles msg.sender's existing position against funding that arrived since
    ///         their last redemption or claim. Requires no USDR.
    /// @dev    Reverts with {NothingToClaim} if the position is owed nothing.
    /// @return usdcAmount USDC paid out, in 6-decimal raw units.
    function claim() external returns (uint256 usdcAmount);

    /// @notice Same as {claim}, paying the USDC to `receiver`.
    /// @param  receiver USDC recipient; address(0) is treated as msg.sender.
    /// @return usdcAmount USDC paid out, in 6-decimal raw units.
    function claim(address receiver) external returns (uint256 usdcAmount);

    // ---------------------------------------------------------------------
    // Funding & wind-down (owner)
    // ---------------------------------------------------------------------

    /// @notice Pulls `usdcAmount` USDC from the owner into the contract.
    /// @dev    Reverts with {FundingExceedsExpected} if it would push {totalFunded} past
    ///         {expectedFunding}; {remainingFunding} reports the exact amount that fits. The
    ///         funding that reaches {expectedFunding} stamps {fullyFundedAt} and starts the
    ///         180-day sweep countdown. The USDC balance must increase by exactly `usdcAmount`;
    ///         otherwise the call reverts with {FundingReceiptMismatch} and no funding is
    ///         recorded.
    /// @param  usdcAmount USDC to pull in, in 6-decimal raw units.
    function fund(uint256 usdcAmount) external;

    /// @notice Recognizes USDC already held by this contract as funding without pulling more
    ///         from the owner.
    /// @dev    Recovers from an accidental raw transfer. Only balance above the accounted
    ///         reserve (`totalFunded - totalPaid`) may be recognized, and the normal
    ///         {expectedFunding} cap still applies. Reaching the cap starts the sweep countdown.
    /// @param  usdcAmount Existing, unaccounted USDC to add to {totalFunded}.
    function fundFromBalance(uint256 usdcAmount) external;

    /// @notice Raises the redemption rate. The rate can never be lowered.
    /// @dev    Raises {expectedFunding}, so more USDC may be funded and every share — including
    ///         those of accounts that already redeemed — becomes worth more once it is. Nothing
    ///         already paid is ever clawed back. Because the contract is no longer fully
    ///         funded afterwards, {fullyFundedAt} is cleared and the sweep countdown restarts
    ///         when the top-up lands.
    /// @param  newRate New rate in USDC raw units per whole USDR; must exceed the current rate.
    function setRate(uint256 newRate) external;

    /// @notice Sweeps the contract's entire USDC balance to `to` and permanently closes the
    ///         contract. Allowed from 180 days after full funding ({sweepUnlockTime}).
    /// @dev    This is the single deadline for everyone: holders who never presented their
    ///         USDR and holders who presented it but never claimed the remainder both forfeit
    ///         whatever is left. After the first sweep {redeem}, {claim}, {fund},
    ///         {fundFromBalance} and {setRate} revert with {ContractClosed}; {sweep} itself
    ///         stays callable so USDC that lands later can still be recovered. The first call
    ///         closes successfully even when the balance is zero; a later empty sweep reverts
    ///         with {ZeroAmount}.
    /// @param  to Recipient of the swept USDC.
    function sweep(address to) external;

    /// @notice Recovers the full balance of a stray (non-USDC) ERC-20 sent here.
    /// @dev    Reverts with {ZeroAmount} if the contract holds none of `token`.
    /// @param  token The ERC-20 to rescue (USDC is rejected).
    /// @param  to    Recipient of the rescued balance.
    function rescueERC20(address token, address to) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Total USDC required to redeem the whole supply at the current rate.
    /// @dev    `ceil(totalUSDRSupply * rate / USDR_UNIT)`. Rounded up so that at full funding
    ///         no holder receives less than the rate promises; the owner over-funds by strictly
    ///         less than one raw USDC unit.
    /// @return The expected total funding, in 6-decimal raw units.
    function expectedFunding() external view returns (uint256);

    /// @notice USDC still needed to reach full funding — the exact amount {fund} will accept.
    /// @return `expectedFunding() - totalFunded()`, in 6-decimal raw units.
    function remainingFunding() external view returns (uint256);

    /// @notice True while {totalFunded} equals {expectedFunding}.
    function isFullyFunded() external view returns (bool);

    /// @notice The effective rate right now: USDC per whole USDR at the current funding level.
    /// @dev    `rate * totalFunded / expectedFunding`, rounded down — a display figure. The
    ///         payout formula does not use it (see {previewRedeem}), so it can be off by
    ///         rounding dust; it is 0 before any funding and `rate` at full funding.
    function effectiveRate() external view returns (uint256);

    /// @notice USDC payable right now to an account with no existing position that presents
    ///         `usdrAmount` USDR. Returns 0 once the contract is closed.
    /// @dev    `usdrAmount * totalFunded / totalUSDRSupply`, rounded down. Note the rate does
    ///         not appear: a share's payout is its pro-rata slice of what has actually been
    ///         funded. Use the two-argument overload for an account that has already redeemed.
    /// @param  usdrAmount Amount of USDR, in 9-decimal raw units.
    /// @return The USDC payout, in 6-decimal raw units.
    function previewRedeem(uint256 usdrAmount) external view returns (uint256);

    /// @notice USDC `account` would receive right now by presenting `usdrAmount` more USDR,
    ///         taking its existing position into account.
    /// @dev    `(shares + usdrAmount) * totalFunded / totalUSDRSupply - paid`. With
    ///         `usdrAmount == 0` this equals {claimableUSDC}. Pure arithmetic: it does not
    ///         check the share cap. Returns 0 once the contract is closed.
    /// @param  account    The prospective redeemer.
    /// @param  usdrAmount Additional USDR, in 9-decimal raw units.
    /// @return The USDC payout, in 6-decimal raw units.
    function previewRedeem(address account, uint256 usdrAmount) external view returns (uint256);

    /// @notice USDC `account` can withdraw right now via {claim}; 0 once closed.
    /// @return `shares * totalFunded / totalUSDRSupply - paid`, in 6-decimal raw units.
    function claimableUSDC(address account) external view returns (uint256);

    /// @notice USDC every registered position is still owed at the current funding level;
    ///         0 once closed and all unpaid entitlements have been forfeited.
    /// @dev    `totalShares * totalFunded / totalUSDRSupply - totalPaid`: an upper bound on the
    ///         sum of {claimableUSDC} over all accounts (per-account flooring only ever loses
    ///         dust relative to this aggregate).
    function outstandingUSDC() external view returns (uint256);

    /// @notice USDC currently held by the contract.
    /// @dev    Always at least `totalFunded - totalPaid` while open, which in turn is at least
    ///         {outstandingUSDC}; this is what makes an explicit balance check in {redeem} and
    ///         {claim} unnecessary. Can exceed it by USDC received through raw transfers,
    ///         which is not counted as funding unless deliberately recognized through
    ///         {fundFromBalance}; otherwise it remains recoverable through {sweep}.
    function availableUSDC() external view returns (uint256);

    /// @notice USDR that may still be presented before the share cap is reached.
    /// @return `totalUSDRSupply - totalShares`, in 9-decimal raw units; 0 once closed.
    function maxRedeemableUSDR() external view returns (uint256);

    /// @notice Earliest timestamp at which the owner may sweep.
    /// @return `fullyFundedAt + SWEEP_DELAY`, or `type(uint256).max` while the contract is not
    ///         fully funded (no sweep is scheduled until it is).
    function sweepUnlockTime() external view returns (uint256);
}
