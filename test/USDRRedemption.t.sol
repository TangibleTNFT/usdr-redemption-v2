// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {USDRRedemption} from "../src/USDRRedemption.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockUSDR} from "./mocks/MockUSDR.sol";

contract USDRRedemptionTest is Test {
    // $0.5417 per USDR — deliberately non-round to exercise precision.
    uint256 internal constant RATE = 541_700;
    uint256 internal constant ONE_USDR = 1e9;
    uint256 internal constant ONE_USDC = 1e6;

    MockUSDR internal usdr;
    MockUSDC internal usdc;
    USDRRedemption internal redemption;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdr = new MockUSDR();
        usdc = new MockUSDC();
        redemption = new USDRRedemption(address(usdr), address(usdc), RATE, owner);

        usdc.mint(owner, 100_000_000 * ONE_USDC);
        vm.prank(owner);
        usdc.approve(address(redemption), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _fund(uint256 amount) internal {
        vm.prank(owner);
        redemption.fund(amount);
    }

    function _giveUsdr(address who, uint256 amount) internal {
        usdr.mint(who, amount);
        vm.prank(who);
        usdr.approve(address(redemption), amount);
    }

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    function test_constructor_setsConfig() public view {
        assertEq(address(redemption.usdr()), address(usdr));
        assertEq(address(redemption.usdc()), address(usdc));
        assertEq(redemption.rate(), RATE);
        assertEq(redemption.owner(), owner);
        assertEq(redemption.lastFundingTime(), block.timestamp);
        assertEq(redemption.sweepUnlockTime(), block.timestamp + 180 days);
        assertEq(redemption.SWEEP_DELAY(), 180 days);
        assertEq(redemption.USDR_UNIT(), 1e9);
    }

    function test_constructor_revertsOnZeroUsdr() public {
        vm.expectRevert(USDRRedemption.ZeroAddress.selector);
        new USDRRedemption(address(0), address(usdc), RATE, owner);
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(USDRRedemption.ZeroAddress.selector);
        new USDRRedemption(address(usdr), address(0), RATE, owner);
    }

    function test_constructor_revertsOnZeroRate() public {
        vm.expectRevert(USDRRedemption.ZeroRate.selector);
        new USDRRedemption(address(usdr), address(usdc), 0, owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new USDRRedemption(address(usdr), address(usdc), RATE, address(0));
    }

    function test_constructor_revertsOnIdenticalTokens() public {
        vm.expectRevert(USDRRedemption.IdenticalTokens.selector);
        new USDRRedemption(address(usdr), address(usdr), RATE, owner);
    }

    function test_constructor_revertsOnWrongDecimals() public {
        // USDC (6 decimals) in the USDR slot fails the 9-decimal self-check.
        vm.expectRevert(USDRRedemption.UnexpectedDecimals.selector);
        new USDRRedemption(address(usdc), address(usdr), RATE, owner);
    }

    function test_constructor_emitsDeployed() public {
        vm.expectEmit(true, true, true, true);
        emit USDRRedemption.Deployed(address(usdr), address(usdc), RATE, owner);
        new USDRRedemption(address(usdr), address(usdc), RATE, owner);
    }

    // -----------------------------------------------------------------
    // Rate math (previewRedeem)
    // -----------------------------------------------------------------

    function test_previewRedeem_wholeAmounts() public view {
        assertEq(redemption.previewRedeem(ONE_USDR), 541_700); // $0.5417
        assertEq(redemption.previewRedeem(2 * ONE_USDR), 1_083_400);
        assertEq(redemption.previewRedeem(1_000 * ONE_USDR), 541_700_000);
    }

    function test_previewRedeem_roundsDown() public view {
        // 1.5 USDR * 0.5417 = 0.81255 USDC -> 812_550 units (exact)
        assertEq(redemption.previewRedeem(15e8), 812_550);
        // 1 raw USDR unit (1e-9 USDR) pays out 0
        assertEq(redemption.previewRedeem(1), 0);
        // Smallest amount paying 1 USDC unit: ceil(1e9 / 541700) = 1847
        assertEq(redemption.previewRedeem(1_846), 0);
        assertEq(redemption.previewRedeem(1_847), 1);
    }

    function testFuzz_previewRedeem_isFloorOfExactProduct(uint256 usdrAmount) public view {
        usdrAmount = bound(usdrAmount, 0, 1e30); // far beyond any conceivable USDR supply
        uint256 payout = redemption.previewRedeem(usdrAmount);
        assertLe(payout * ONE_USDR, usdrAmount * RATE);
        assertGt((payout + 1) * ONE_USDR, usdrAmount * RATE);
    }

    // -----------------------------------------------------------------
    // redeem
    // -----------------------------------------------------------------

    function test_redeem_happyPath_defaultReceiver() public {
        _fund(1_000_000 * ONE_USDC);
        _giveUsdr(alice, 100 * ONE_USDR);

        uint256 expectedUsdc = 100 * RATE; // 54.17 USDC

        vm.expectEmit(true, true, true, true, address(redemption));
        emit USDRRedemption.Redeemed(alice, alice, 100 * ONE_USDR, expectedUsdc);
        vm.prank(alice);
        uint256 paid = redemption.redeem(100 * ONE_USDR);

        assertEq(paid, expectedUsdc);
        assertEq(usdc.balanceOf(alice), expectedUsdc);
        assertEq(usdr.balanceOf(alice), 0);
        assertEq(usdr.totalSupply(), 0); // burned, not transferred
        assertEq(usdr.balanceOf(address(redemption)), 0); // never custodied
        assertEq(usdr.allowance(alice, address(redemption)), 0); // allowance spent
        assertEq(redemption.availableUSDC(), 1_000_000 * ONE_USDC - expectedUsdc);
    }

    function test_redeem_explicitReceiver() public {
        _fund(1_000 * ONE_USDC);
        _giveUsdr(alice, 10 * ONE_USDR);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit USDRRedemption.Redeemed(alice, bob, 10 * ONE_USDR, 10 * RATE);
        vm.prank(alice);
        uint256 paid = redemption.redeem(10 * ONE_USDR, bob);

        assertEq(paid, 10 * RATE);
        assertEq(usdc.balanceOf(bob), 10 * RATE);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdr.balanceOf(alice), 0);
    }

    function test_redeem_zeroReceiverDefaultsToSender() public {
        _fund(1_000 * ONE_USDC);
        _giveUsdr(alice, ONE_USDR);

        vm.prank(alice);
        redemption.redeem(ONE_USDR, address(0));

        assertEq(usdc.balanceOf(alice), RATE);
    }

    function test_redeem_revertsOnZeroPayout() public {
        _fund(1_000 * ONE_USDC);
        _giveUsdr(alice, ONE_USDR);

        vm.startPrank(alice);
        vm.expectRevert(USDRRedemption.ZeroPayout.selector);
        redemption.redeem(0);
        // 1846 raw units round down to zero USDC at $0.5417 — no burning USDR for nothing.
        vm.expectRevert(USDRRedemption.ZeroPayout.selector);
        redemption.redeem(1_846);
        vm.stopPrank();
    }

    function test_redeem_revertsWhenUSDCInsufficient() public {
        _fund(50 * ONE_USDC);
        _giveUsdr(alice, 100 * ONE_USDR); // needs 54.17 USDC, only 50 on hand

        vm.expectRevert(
            abi.encodeWithSelector(USDRRedemption.InsufficientUSDC.selector, 100 * RATE, 50 * ONE_USDC)
        );
        vm.prank(alice);
        redemption.redeem(100 * ONE_USDR);
    }

    function test_redeem_revertsWhenNeverFunded() public {
        _giveUsdr(alice, ONE_USDR);
        vm.expectRevert(abi.encodeWithSelector(USDRRedemption.InsufficientUSDC.selector, RATE, 0));
        vm.prank(alice);
        redemption.redeem(ONE_USDR);
    }

    function test_redeem_exactBalanceBoundary() public {
        // Payout exactly equal to the balance succeeds and drains the contract...
        _fund(100 * RATE);
        _giveUsdr(alice, 200 * ONE_USDR);

        vm.prank(alice);
        redemption.redeem(100 * ONE_USDR);
        assertEq(redemption.availableUSDC(), 0);

        // ...and one unit short of the payout reverts (all-or-nothing).
        _fund(100 * RATE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(USDRRedemption.InsufficientUSDC.selector, 100 * RATE, 100 * RATE - 1)
        );
        vm.prank(alice);
        redemption.redeem(100 * ONE_USDR);
    }

    function test_redeem_revertsWithoutAllowance() public {
        _fund(1_000 * ONE_USDC);
        usdr.mint(alice, ONE_USDR); // no approval

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(redemption), 0, ONE_USDR
            )
        );
        vm.prank(alice);
        redemption.redeem(ONE_USDR);
    }

    function test_redeem_revertsWhenUSDRPaused() public {
        _fund(1_000 * ONE_USDC);
        _giveUsdr(alice, ONE_USDR);
        usdr.setPaused(true);

        vm.expectRevert("Pausable: paused");
        vm.prank(alice);
        redemption.redeem(ONE_USDR);
    }

    function test_redeem_firstComeFirstServed() public {
        _fund(60 * ONE_USDC);
        _giveUsdr(alice, 100 * ONE_USDR); // worth 54.17 USDC
        _giveUsdr(bob, 100 * ONE_USDR);

        // Alice gets in first and takes most of the pot.
        vm.prank(alice);
        redemption.redeem(100 * ONE_USDR);
        assertEq(redemption.availableUSDC(), 60 * ONE_USDC - 100 * RATE); // 5.83 USDC left

        // Bob's full redemption no longer fits...
        vm.expectRevert(
            abi.encodeWithSelector(
                USDRRedemption.InsufficientUSDC.selector, 100 * RATE, 60 * ONE_USDC - 100 * RATE
            )
        );
        vm.prank(bob);
        redemption.redeem(100 * ONE_USDR);

        // ...but a right-sized one does.
        uint256 maxUsdr = redemption.maxRedeemableUSDR();
        vm.prank(bob);
        redemption.redeem(maxUsdr);
        assertEq(usdc.balanceOf(bob), redemption.previewRedeem(maxUsdr));
    }

    function test_redeem_resumesAfterTopUp() public {
        _giveUsdr(alice, 200 * ONE_USDR);

        _fund(100 * RATE);
        vm.prank(alice);
        redemption.redeem(100 * ONE_USDR);

        // Pot empty — next redeem reverts; a top-up re-enables it.
        vm.expectRevert(abi.encodeWithSelector(USDRRedemption.InsufficientUSDC.selector, 100 * RATE, 0));
        vm.prank(alice);
        redemption.redeem(100 * ONE_USDR);

        _fund(100 * RATE);
        vm.prank(alice);
        redemption.redeem(100 * ONE_USDR);
        assertEq(usdc.balanceOf(alice), 200 * RATE);
    }

    function testFuzz_redeem_conservation(uint256 usdrAmount, uint256 funding) public {
        usdrAmount = bound(usdrAmount, 1_847, 2e8 * ONE_USDR); // >= smallest non-zero payout
        funding = bound(funding, 1, 1e8 * ONE_USDC); // within the owner's minted balance
        _fund(funding);
        _giveUsdr(alice, usdrAmount);

        uint256 payout = redemption.previewRedeem(usdrAmount);
        vm.prank(alice);
        if (payout > funding) {
            vm.expectRevert(
                abi.encodeWithSelector(USDRRedemption.InsufficientUSDC.selector, payout, funding)
            );
            redemption.redeem(usdrAmount);
        } else {
            redemption.redeem(usdrAmount);
            // I1/I2: USDC out matches USDR burned at the fixed rate, never exceeding holdings.
            assertEq(usdc.balanceOf(alice), payout);
            assertEq(usdr.totalSupply(), 0);
            assertEq(redemption.availableUSDC(), funding - payout);
        }
    }

    // -----------------------------------------------------------------
    // fund
    // -----------------------------------------------------------------

    function test_fund_transfersAndStampsClock() public {
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 3 days);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit USDRRedemption.Funded(owner, 500 * ONE_USDC);
        _fund(500 * ONE_USDC);

        assertEq(redemption.availableUSDC(), 500 * ONE_USDC);
        assertEq(redemption.lastFundingTime(), t0 + 3 days);
        assertEq(redemption.sweepUnlockTime(), t0 + 3 days + 180 days);
    }

    function test_fund_resetsClockOnEachFunding() public {
        _fund(ONE_USDC);
        uint256 first = redemption.lastFundingTime();

        vm.warp(block.timestamp + 100 days);
        _fund(ONE_USDC);

        assertEq(redemption.lastFundingTime(), first + 100 days);
    }

    function test_fund_revertsForNonOwner() public {
        usdc.mint(alice, ONE_USDC);
        vm.startPrank(alice);
        usdc.approve(address(redemption), ONE_USDC);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        redemption.fund(ONE_USDC);
        vm.stopPrank();
    }

    function test_fund_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(USDRRedemption.ZeroAmount.selector);
        redemption.fund(0);
    }

    function test_fund_revertsWithoutUSDCAllowance() public {
        vm.startPrank(owner);
        usdc.approve(address(redemption), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(redemption), 0, ONE_USDC
            )
        );
        redemption.fund(ONE_USDC);
        vm.stopPrank();
    }

    function test_rawTransferDoesNotResetClock() public {
        // Anyone can still push USDC in with a raw transfer, but it cannot grief the
        // sweep clock — it only increases the redeemable balance.
        uint256 stamp = redemption.lastFundingTime();
        vm.warp(block.timestamp + 10 days);

        usdc.mint(bob, 5 * ONE_USDC);
        vm.prank(bob);
        usdc.transfer(address(redemption), 5 * ONE_USDC);

        assertEq(redemption.lastFundingTime(), stamp);
        assertEq(redemption.availableUSDC(), 5 * ONE_USDC);
    }

    // -----------------------------------------------------------------
    // sweep
    // -----------------------------------------------------------------

    function test_sweep_revertsBeforeUnlock() public {
        _fund(100 * ONE_USDC);
        uint256 unlock = redemption.sweepUnlockTime();

        vm.warp(unlock - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(USDRRedemption.SweepLocked.selector, unlock));
        redemption.sweep(owner);
    }

    function test_sweep_succeedsAtUnlock() public {
        _fund(100 * ONE_USDC);
        vm.warp(redemption.sweepUnlockTime());

        vm.expectEmit(true, true, true, true, address(redemption));
        emit USDRRedemption.Swept(bob, 100 * ONE_USDC);
        vm.prank(owner);
        redemption.sweep(bob);

        assertEq(usdc.balanceOf(bob), 100 * ONE_USDC);
        assertEq(redemption.availableUSDC(), 0);
    }

    function test_sweep_clockResetByNewFunding() public {
        _fund(100 * ONE_USDC);
        vm.warp(block.timestamp + 179 days);
        _fund(ONE_USDC); // resets the clock with one day to spare

        vm.warp(block.timestamp + 1 days); // would have passed the original deadline
        uint256 unlock = redemption.sweepUnlockTime();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(USDRRedemption.SweepLocked.selector, unlock));
        redemption.sweep(owner);

        vm.warp(redemption.sweepUnlockTime());
        vm.prank(owner);
        redemption.sweep(owner);
        assertEq(usdc.balanceOf(owner), 100_000_000 * ONE_USDC); // everything back
    }

    function test_sweep_neverFunded_unlocksFromDeployment() public {
        // Clock starts at deployment, so even donations received before any fund()
        // are timelocked (I5).
        usdc.mint(address(redemption), 7 * ONE_USDC);

        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(USDRRedemption.SweepLocked.selector, redemption.sweepUnlockTime())
        );
        redemption.sweep(owner);

        vm.warp(redemption.sweepUnlockTime());
        redemption.sweep(bob);
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), 7 * ONE_USDC);
    }

    function test_sweep_revertsForNonOwner() public {
        vm.warp(redemption.sweepUnlockTime());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        redemption.sweep(alice);
    }

    function test_sweep_revertsOnZeroAddress() public {
        vm.warp(redemption.sweepUnlockTime());
        vm.prank(owner);
        vm.expectRevert(USDRRedemption.ZeroAddress.selector);
        redemption.sweep(address(0));
    }

    // -----------------------------------------------------------------
    // rescueERC20
    // -----------------------------------------------------------------

    function test_rescue_straysRecovered() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(redemption), 42e6);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit USDRRedemption.Rescued(address(stray), bob, 42e6);
        vm.prank(owner);
        redemption.rescueERC20(address(stray), bob);

        assertEq(stray.balanceOf(bob), 42e6);
    }

    function test_rescue_strayUSDRRecoverable() public {
        // The contract never holds USDR in normal operation; a raw USDR transfer is a
        // stray like any other token and must be recoverable.
        usdr.mint(address(redemption), 3 * ONE_USDR);

        vm.prank(owner);
        redemption.rescueERC20(address(usdr), alice);
        assertEq(usdr.balanceOf(alice), 3 * ONE_USDR);
    }

    function test_rescue_cannotBypassUSDCTimelock() public {
        _fund(100 * ONE_USDC);
        vm.prank(owner);
        vm.expectRevert(USDRRedemption.CannotRescueUSDC.selector);
        redemption.rescueERC20(address(usdc), owner);
    }

    function test_rescue_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        redemption.rescueERC20(address(usdr), alice);
    }

    function test_rescue_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(USDRRedemption.ZeroAddress.selector);
        redemption.rescueERC20(address(usdr), address(0));
    }

    // -----------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------

    function test_views_capacity() public {
        assertEq(redemption.availableUSDC(), 0);
        assertEq(redemption.maxRedeemableUSDR(), 0);

        _fund(541_700); // exactly 1 USDR worth
        assertEq(redemption.availableUSDC(), 541_700);
        assertEq(redemption.maxRedeemableUSDR(), ONE_USDR);

        _fund(1); // 541_701 total: still only 1.000000001846... USDR redeemable
        assertEq(redemption.maxRedeemableUSDR(), (541_701 * ONE_USDR) / RATE);
    }

    function test_maxRedeemable_returnsZeroAtDustBalance() public {
        // L-01: at 1 raw USDC unit the inverse-rounded amount (1846 USDR) previews to a
        // zero payout, so the helper must report 0 rather than an amount that reverts.
        _fund(1);
        uint256 maxUsdr = redemption.maxRedeemableUSDR();
        assertEq(maxUsdr, 0, "must not advertise a reverting amount");
        assertEq(redemption.previewRedeem((1 * ONE_USDR) / RATE), 0); // the old, reverting value

        // One unit more is enough to pay out, so the helper resumes advertising a usable amount.
        _fund(1);
        maxUsdr = redemption.maxRedeemableUSDR();
        assertGt(redemption.previewRedeem(maxUsdr), 0);
        _giveUsdr(alice, maxUsdr);
        vm.prank(alice);
        redemption.redeem(maxUsdr); // does not revert
    }

    function testFuzz_maxRedeemableUSDR_neverReverts(uint256 funding) public {
        funding = bound(funding, 1, 1e8 * ONE_USDC);
        _fund(funding);

        uint256 maxUsdr = redemption.maxRedeemableUSDR();
        // The advertised max always fits within the available balance (R3)...
        assertLe(redemption.previewRedeem(maxUsdr), funding);

        if (redemption.previewRedeem(maxUsdr) == 0) return; // sub-unit funding edge
        // ...so redeeming exactly that amount never reverts.
        _giveUsdr(alice, maxUsdr);
        vm.prank(alice);
        redemption.redeem(maxUsdr);
    }

    // -----------------------------------------------------------------
    // Ownership (Ownable2Step)
    // -----------------------------------------------------------------

    function test_ownership_twoStepTransfer() public {
        vm.prank(owner);
        redemption.transferOwnership(bob);

        // Nothing changes until the new owner accepts.
        assertEq(redemption.owner(), owner);
        assertEq(redemption.pendingOwner(), bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        redemption.fund(1);

        vm.prank(bob);
        redemption.acceptOwnership();
        assertEq(redemption.owner(), bob);

        // Old owner is fully demoted.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        redemption.sweep(owner);
    }
}
