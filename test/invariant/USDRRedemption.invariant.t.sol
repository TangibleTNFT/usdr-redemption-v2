// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {USDRRedemption} from "../../src/USDRRedemption.sol";
import {IUSDRRedemption} from "../../src/interfaces/IUSDRRedemption.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockUSDR} from "../mocks/MockUSDR.sol";

/// @notice Drives the redemption through random fund/fundFromBalance/redeem/claim/setRate/
///         donate/sweep sequences while tracking ghost totals, so the invariant suite can
///         assert solvency, pro-rata accounting, value conservation and the wind-down rules
///         across arbitrary state transitions.
contract Handler is Test {
    USDRRedemption internal immutable redemption;
    MockUSDR internal immutable usdr;
    MockUSDC internal immutable usdc;
    address internal immutable owner;

    uint256 public totalFunded;
    uint256 public totalRecognized;
    uint256 public totalDonated;
    uint256 public totalPaidOut;
    uint256 public totalSwept;
    uint256 public lastObservedRate;
    uint256 public sweepCount;

    address[3] public actors = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
    mapping(address => uint256) public ghostShares;
    mapping(address => uint256) public ghostPaid;

    constructor(USDRRedemption redemption_, MockUSDR usdr_, MockUSDC usdc_, address owner_) {
        redemption = redemption_;
        usdr = usdr_;
        usdc = usdc_;
        owner = owner_;
        lastObservedRate = redemption_.rate();
    }

    function fund(uint256 amount) external {
        uint256 remaining = redemption.remainingFunding();
        if (remaining == 0 || redemption.closed()) return;
        amount = bound(amount, 1, remaining);
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(redemption), amount);
        redemption.fund(amount);
        vm.stopPrank();
        totalFunded += amount;
    }

    /// @dev Over-funding must always be rejected with the exact remainder.
    function fundTooMuchMustRevert(uint256 excess) external {
        if (redemption.closed()) return;
        uint256 remaining = redemption.remainingFunding();
        excess = bound(excess, 1, 1e12);
        usdc.mint(owner, remaining + excess);
        vm.startPrank(owner);
        usdc.approve(address(redemption), remaining + excess);
        vm.expectRevert(
            abi.encodeWithSelector(IUSDRRedemption.FundingExceedsExpected.selector, remaining + excess, remaining)
        );
        redemption.fund(remaining + excess);
        vm.stopPrank();
    }

    /// @dev Raw USDC arrival (donation / direct transfer) that bypasses fund().
    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1e6 * 1e6);
        usdc.mint(address(redemption), amount);
        totalDonated += amount;
    }

    function fundFromBalance(uint256 amount) external {
        if (redemption.closed()) return;
        uint256 remaining = redemption.remainingFunding();
        uint256 accountedReserve = redemption.totalFunded() - redemption.totalPaid();
        uint256 balance = redemption.availableUSDC();
        uint256 unaccounted = balance > accountedReserve ? balance - accountedReserve : 0;
        uint256 available = remaining < unaccounted ? remaining : unaccounted;
        if (available == 0) return;

        amount = bound(amount, 1, available);
        vm.prank(owner);
        redemption.fundFromBalance(amount);
        totalFunded += amount;
        totalRecognized += amount;
    }

    function redeem(uint256 seed, uint256 usdrAmount) external {
        uint256 maxUsdr = redemption.maxRedeemableUSDR();
        if (maxUsdr == 0) return; // cap reached or closed
        usdrAmount = bound(usdrAmount, 1, maxUsdr);

        address actor = actors[seed % actors.length];
        uint256 expected = redemption.previewRedeem(actor, usdrAmount);
        usdr.mint(actor, usdrAmount);
        vm.startPrank(actor);
        usdr.approve(address(redemption), usdrAmount);
        uint256 paid = redemption.redeem(usdrAmount);
        vm.stopPrank();
        assertEq(paid, expected, "redeem paid what preview promised");

        ghostShares[actor] += usdrAmount;
        ghostPaid[actor] += paid;
        totalPaidOut += paid;
    }

    function claim(uint256 seed) external {
        address actor = actors[seed % actors.length];
        uint256 claimable = redemption.claimableUSDC(actor);
        if (claimable == 0 || redemption.closed()) return;
        vm.prank(actor);
        uint256 paid = redemption.claim();
        assertEq(paid, claimable, "claim paid what the view promised");

        ghostPaid[actor] += paid;
        totalPaidOut += paid;
    }

    function setRate(uint256 bump) external {
        if (redemption.closed()) return;
        uint256 current = redemption.rate();
        bump = bound(bump, 1, 100_000); // up to +$0.10 per call
        vm.prank(owner);
        redemption.setRate(current + bump);

        assertGe(redemption.rate(), lastObservedRate, "rate moved down");
        lastObservedRate = redemption.rate();
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 0, 200 days);
        vm.warp(block.timestamp + secs);
    }

    function sweep() external {
        if (block.timestamp < redemption.sweepUnlockTime()) return; // respect the timelock
        uint256 bal = redemption.availableUSDC();
        if (bal == 0) return; // sweep() rejects an empty balance with ZeroAmount
        vm.prank(owner);
        redemption.sweep(owner);
        totalSwept += bal;
        sweepCount++;
    }

    /// @dev Before the unlock, sweep must always revert — baked into the fuzz campaign.
    function sweepEarlyMustRevert() external {
        uint256 unlock = redemption.sweepUnlockTime();
        if (block.timestamp >= unlock) return;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, unlock));
        redemption.sweep(owner);
    }

    /// @dev Once closed, every mutator except sweep must revert.
    function closedMustRejectMutators(uint256 seed) external {
        if (!redemption.closed()) return;
        address actor = actors[seed % actors.length];
        usdr.mint(actor, 1);
        vm.startPrank(actor);
        usdr.approve(address(redemption), 1);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.redeem(1);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.claim();
        vm.stopPrank();

        usdc.mint(owner, 1);
        vm.startPrank(owner);
        usdc.approve(address(redemption), 1);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.fund(1);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.fundFromBalance(1);
        uint256 newRate = redemption.rate() + 1;
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.setRate(newRate);
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract USDRRedemptionInvariants is Test {
    uint256 internal constant RATE = 541_700;
    uint256 internal constant TOTAL_SUPPLY = 35_909_552 * 1e9;

    MockUSDR internal usdr;
    MockUSDC internal usdc;
    USDRRedemption internal redemption;
    Handler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        usdr = new MockUSDR();
        usdc = new MockUSDC();
        redemption = new USDRRedemption(address(usdr), address(usdc), RATE, TOTAL_SUPPLY, owner);
        handler = new Handler(redemption, usdr, usdc, owner);
        targetContract(address(handler));
    }

    /// @notice I1: the contract can always pay what it owes — the balance covers the funded
    ///         amount not yet paid out (which bounds the sum of all claims) while open.
    function invariant_solvency() public view {
        if (redemption.closed()) return;
        assertGe(redemption.availableUSDC(), redemption.totalFunded() - redemption.totalPaid());
        assertGe(redemption.availableUSDC(), redemption.outstandingUSDC());

        uint256 sumClaimable;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sumClaimable += redemption.claimableUSDC(handler.actors(i));
        }
        assertLe(sumClaimable, redemption.outstandingUSDC());
        assertGe(redemption.availableUSDC(), sumClaimable);
    }

    /// @notice I2: every position is paid at most its pro-rata entitlement, and the contract's
    ///         per-account and aggregate accounting agree with the ghost ledger.
    function invariant_proRataAccounting() public view {
        uint256 sumShares;
        uint256 sumPaid;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            (uint256 shares, uint256 paid) = redemption.positions(actor);
            assertEq(shares, handler.ghostShares(actor), "shares ledger");
            assertEq(paid, handler.ghostPaid(actor), "paid ledger");
            assertLe(paid, (shares * redemption.totalFunded()) / TOTAL_SUPPLY, "paid beyond entitlement");
            sumShares += shares;
            sumPaid += paid;
        }
        assertEq(redemption.totalShares(), sumShares);
        assertEq(redemption.totalPaid(), sumPaid);
        assertEq(redemption.totalPaid(), handler.totalPaidOut());
    }

    /// @notice I6: the caps hold — never more shares than the supply, never more funding than
    ///         expected, never more paid out than funded.
    function invariant_caps() public view {
        assertLe(redemption.totalShares(), TOTAL_SUPPLY);
        assertLe(redemption.totalFunded(), redemption.expectedFunding());
        assertLe(redemption.totalPaid(), redemption.totalFunded());
        assertEq(redemption.totalFunded(), handler.totalFunded());
        assertEq(redemption.remainingFunding(), redemption.expectedFunding() - redemption.totalFunded());
    }

    /// @notice I3: the rate never decreases.
    function invariant_rateMonotonic() public view {
        assertEq(redemption.rate(), handler.lastObservedRate());
        assertGe(redemption.rate(), RATE);
    }

    /// @notice Value conservation: every USDC in (funded + donated) equals every USDC out
    ///         (paid + swept) plus the live balance.
    function invariant_valueConservation() public view {
        assertEq(
            handler.totalFunded() - handler.totalRecognized() + handler.totalDonated(),
            handler.totalPaidOut() + handler.totalSwept() + redemption.availableUSDC()
        );
    }

    /// @notice I5: full funding is exactly what stamps the clock, the unlock is exactly 180
    ///         days after it, and no timestamp is ever in the future.
    function invariant_fullFundingClock() public view {
        bool full = redemption.totalFunded() == redemption.expectedFunding();
        assertEq(redemption.isFullyFunded(), full);
        assertEq(redemption.fullyFundedAt() != 0, full);
        if (full) {
            assertLe(redemption.fullyFundedAt(), block.timestamp);
            assertEq(redemption.sweepUnlockTime(), redemption.fullyFundedAt() + 180 days);
        } else {
            assertEq(redemption.sweepUnlockTime(), type(uint256).max);
        }
    }

    /// @notice I7: a sweep happens only after full funding + 180 days, closes the contract for
    ///         good, and a closed contract is fully funded (nothing can un-fund it).
    function invariant_terminalClose() public view {
        assertEq(redemption.closed(), handler.sweepCount() > 0);
        if (!redemption.closed()) return;
        assertTrue(redemption.isFullyFunded());
        assertGe(block.timestamp, redemption.sweepUnlockTime());
        assertEq(redemption.maxRedeemableUSDR(), 0);
    }
}
