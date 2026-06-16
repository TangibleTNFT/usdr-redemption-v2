// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {USDRRedemption} from "../../src/USDRRedemption.sol";
import {IUSDRRedemption} from "../../src/interfaces/IUSDRRedemption.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockUSDR} from "../mocks/MockUSDR.sol";

/// @notice Drives the redemption through random fund/redeem/donate/sweep sequences while
///         tracking ghost totals, so the invariant suite can assert the value-conservation
///         identity and the sweep timelock across arbitrary state transitions (O-09).
contract Handler is Test {
    USDRRedemption internal immutable redemption;
    MockUSDR internal immutable usdr;
    MockUSDC internal immutable usdc;
    address internal immutable owner;

    uint256 public totalFunded;
    uint256 public totalDonated;
    uint256 public totalPaidOut;
    uint256 public totalSwept;
    uint256 public lastObservedFundingTime;

    address[3] internal actors = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];

    constructor(USDRRedemption redemption_, MockUSDR usdr_, MockUSDC usdc_, address owner_) {
        redemption = redemption_;
        usdr = usdr_;
        usdc = usdc_;
        owner = owner_;
        lastObservedFundingTime = redemption_.lastFundingTime();
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1e9 * 1e6);
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(redemption), amount);
        redemption.fund(amount);
        vm.stopPrank();
        totalFunded += amount;

        uint256 t = redemption.lastFundingTime();
        assertGe(t, lastObservedFundingTime, "lastFundingTime moved backwards");
        lastObservedFundingTime = t;
    }

    /// @dev Raw USDC arrival (donation / direct transfer) that bypasses fund().
    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1e9 * 1e6);
        usdc.mint(address(redemption), amount);
        totalDonated += amount;
    }

    function redeem(uint256 seed, uint256 usdrAmount) external {
        uint256 maxUsdr = redemption.maxRedeemableUSDR();
        if (maxUsdr == 0) return;
        usdrAmount = bound(usdrAmount, 1, maxUsdr);
        uint256 payout = redemption.previewRedeem(usdrAmount);
        if (payout == 0) return;

        address actor = actors[seed % actors.length];
        usdr.mint(actor, usdrAmount);
        vm.startPrank(actor);
        usdr.approve(address(redemption), usdrAmount);
        redemption.redeem(usdrAmount);
        vm.stopPrank();
        totalPaidOut += payout;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 0, 200 days);
        vm.warp(block.timestamp + secs);
    }

    function sweep() external {
        if (block.timestamp < redemption.sweepUnlockTime()) return; // respect the timelock
        uint256 bal = redemption.availableUSDC();
        vm.prank(owner);
        redemption.sweep(owner);
        totalSwept += bal;
    }

    /// @dev Before the unlock, sweep must always revert — baked into the fuzz campaign.
    function sweepEarlyMustRevert() external {
        uint256 unlock = redemption.sweepUnlockTime();
        if (block.timestamp >= unlock) return;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, unlock));
        redemption.sweep(owner);
    }
}

contract USDRRedemptionInvariants is Test {
    uint256 internal constant RATE = 541_700;

    MockUSDR internal usdr;
    MockUSDC internal usdc;
    USDRRedemption internal redemption;
    Handler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        usdr = new MockUSDR();
        usdc = new MockUSDC();
        redemption = new USDRRedemption(address(usdr), address(usdc), RATE, owner);
        handler = new Handler(redemption, usdr, usdc, owner);
        targetContract(address(handler));
    }

    /// @notice I1/I2: every USDC in (funded + donated) equals every USDC out (paid + swept)
    ///         plus the live balance — value is conserved across all transitions.
    function invariant_valueConservation() public view {
        assertEq(
            handler.totalFunded() + handler.totalDonated(),
            handler.totalPaidOut() + handler.totalSwept() + redemption.availableUSDC()
        );
    }

    /// @notice lastFundingTime is monotonic and never in the future.
    function invariant_fundingTimeMonotonic() public view {
        assertEq(redemption.lastFundingTime(), handler.lastObservedFundingTime());
        assertLe(redemption.lastFundingTime(), block.timestamp);
    }

    /// @notice The sweep unlock is always exactly lastFundingTime + 180 days (I5).
    function invariant_sweepUnlockTracksFunding() public view {
        assertEq(redemption.sweepUnlockTime(), redemption.lastFundingTime() + 180 days);
    }
}
