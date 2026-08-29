// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {USDRRedemption} from "../src/USDRRedemption.sol";
import {IUSDRRedemption} from "../src/interfaces/IUSDRRedemption.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockUSDR} from "./mocks/MockUSDR.sol";
import {ReentrantUSDC} from "./mocks/ReentrantUSDC.sol";

/// @notice ERC-20 that reports success from transferFrom while delivering one unit less,
///         used to prove nominal funding can never overstate the actual reserve.
contract ShortTransferUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount - 1);
        return true;
    }
}

contract USDRRedemptionTest is Test {
    // $0.5417 per USDR — deliberately non-round to exercise precision.
    uint256 internal constant RATE = 541_700;
    uint256 internal constant ONE_USDR = 1e9;
    uint256 internal constant ONE_USDC = 1e6;
    // The real deploy value: 35,909,552 USDR.
    uint256 internal constant TOTAL_SUPPLY = 35_909_552 * ONE_USDR;
    // A whole-USDR supply makes expectedFunding exact: 35_909_552 * 541_700 = 19,452,204.3184 USDC.
    uint256 internal constant EXPECTED = 35_909_552 * RATE;

    MockUSDR internal usdr;
    MockUSDC internal usdc;
    USDRRedemption internal redemption;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        usdr = new MockUSDR();
        usdc = new MockUSDC();
        redemption = _deploy(RATE, TOTAL_SUPPLY);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// @dev Fresh contract with the owner funded and approved for any amount.
    function _deploy(uint256 rate_, uint256 totalSupply_) internal returns (USDRRedemption r) {
        r = new USDRRedemption(address(usdr), address(usdc), rate_, totalSupply_, owner);
        usdc.mint(owner, 100_000_000 * ONE_USDC);
        vm.prank(owner);
        usdc.approve(address(r), type(uint256).max);
    }

    function _fund(uint256 amount) internal {
        _fund(redemption, amount);
    }

    function _fund(USDRRedemption r, uint256 amount) internal {
        vm.prank(owner);
        r.fund(amount);
    }

    function _giveUsdr(address who, uint256 amount) internal {
        _giveUsdr(redemption, who, amount);
    }

    function _giveUsdr(USDRRedemption r, address who, uint256 amount) internal {
        usdr.mint(who, amount);
        vm.prank(who);
        usdr.approve(address(r), amount);
    }

    function _redeem(USDRRedemption r, address who, uint256 amount) internal returns (uint256) {
        _giveUsdr(r, who, amount);
        vm.prank(who);
        return r.redeem(amount);
    }

    /// @dev Claims if anything is owed; returns the amount paid (0 if nothing was owed).
    function _claimIfAny(USDRRedemption r, address who) internal returns (uint256) {
        if (r.claimableUSDC(who) == 0) return 0;
        vm.prank(who);
        return r.claim();
    }

    /// @dev Independently computed pro-rata entitlement: floor(shares * funded / supply).
    function _entitled(uint256 shares, uint256 funded, uint256 supply) internal pure returns (uint256) {
        return (shares * funded) / supply;
    }

    function _shares(address who) internal view returns (uint256 s) {
        (s,) = redemption.positions(who);
    }

    function _paid(address who) internal view returns (uint256 p) {
        (, p) = redemption.positions(who);
    }

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    function test_constructor_setsConfig() public view {
        assertEq(address(redemption.usdr()), address(usdr));
        assertEq(address(redemption.usdc()), address(usdc));
        assertEq(redemption.rate(), RATE);
        assertEq(redemption.totalUSDRSupply(), TOTAL_SUPPLY);
        assertEq(redemption.owner(), owner);
        assertEq(redemption.SWEEP_DELAY(), 180 days);
        assertEq(redemption.USDR_UNIT(), 1e9);

        assertEq(redemption.expectedFunding(), EXPECTED);
        assertEq(redemption.remainingFunding(), EXPECTED);
        assertEq(redemption.totalFunded(), 0);
        assertEq(redemption.totalShares(), 0);
        assertEq(redemption.totalPaid(), 0);
        assertEq(redemption.fullyFundedAt(), 0);
        assertFalse(redemption.isFullyFunded());
        assertFalse(redemption.closed());
        assertEq(redemption.sweepUnlockTime(), type(uint256).max);
        assertEq(redemption.maxRedeemableUSDR(), TOTAL_SUPPLY);
    }

    function test_constructor_revertsOnZeroUsdr() public {
        vm.expectRevert(IUSDRRedemption.ZeroAddress.selector);
        new USDRRedemption(address(0), address(usdc), RATE, TOTAL_SUPPLY, owner);
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(IUSDRRedemption.ZeroAddress.selector);
        new USDRRedemption(address(usdr), address(0), RATE, TOTAL_SUPPLY, owner);
    }

    function test_constructor_revertsOnZeroRate() public {
        vm.expectRevert(IUSDRRedemption.ZeroRate.selector);
        new USDRRedemption(address(usdr), address(usdc), 0, TOTAL_SUPPLY, owner);
    }

    function test_constructor_revertsOnZeroTotalSupply() public {
        vm.expectRevert(IUSDRRedemption.ZeroTotalSupply.selector);
        new USDRRedemption(address(usdr), address(usdc), RATE, 0, owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new USDRRedemption(address(usdr), address(usdc), RATE, TOTAL_SUPPLY, address(0));
    }

    function test_constructor_revertsOnIdenticalTokens() public {
        vm.expectRevert(IUSDRRedemption.IdenticalTokens.selector);
        new USDRRedemption(address(usdr), address(usdr), RATE, TOTAL_SUPPLY, owner);
    }

    function test_constructor_revertsOnWrongDecimals() public {
        // USDC (6 decimals) in the USDR slot fails the 9-decimal self-check.
        vm.expectRevert(IUSDRRedemption.UnexpectedDecimals.selector);
        new USDRRedemption(address(usdc), address(usdr), RATE, TOTAL_SUPPLY, owner);
    }

    function test_constructor_revertsOnSupplyOverflow() public {
        // Position.shares is uint128, so the supply must fit.
        vm.expectRevert(IUSDRRedemption.ConfigOverflow.selector);
        new USDRRedemption(address(usdr), address(usdc), RATE, uint256(type(uint128).max) + 1, owner);
        // The boundary itself is fine (with a rate small enough to keep expectedFunding in range).
        new USDRRedemption(address(usdr), address(usdc), 1, type(uint128).max, owner);
    }

    function test_constructor_revertsOnExpectedFundingOverflow() public {
        // Position.paid is uint128, so ceil(supply * rate / 1e9) must fit: with the supply at
        // the uint128 ceiling, a rate of 2e9 doubles it past the bound.
        vm.expectRevert(IUSDRRedemption.ConfigOverflow.selector);
        new USDRRedemption(address(usdr), address(usdc), 2e9, type(uint128).max, owner);
    }

    function test_constructor_emitsDeployed() public {
        vm.expectEmit(true, true, true, true);
        emit IUSDRRedemption.Deployed(address(usdr), address(usdc), RATE, TOTAL_SUPPLY, owner);
        new USDRRedemption(address(usdr), address(usdc), RATE, TOTAL_SUPPLY, owner);
    }

    // -----------------------------------------------------------------
    // Funding math (expectedFunding / remainingFunding / effectiveRate)
    // -----------------------------------------------------------------

    function test_expectedFunding_deployValues() public {
        // 35,909,552 USDR at $0.532 = 19,103,881.664 USDC, exactly.
        USDRRedemption r = _deploy(532_000, TOTAL_SUPPLY);
        assertEq(r.expectedFunding(), 19_103_881_664_000);
    }

    function test_expectedFunding_roundsUp() public {
        // 1.000000001 USDR * $0.5417 = 541,700.0005417 raw USDC -> rounds UP to 541,701 so the
        // holder of that supply is never short-changed; the owner over-funds by < 1 raw unit.
        USDRRedemption r = _deploy(RATE, ONE_USDR + 1);
        assertEq(r.expectedFunding(), 541_701);
        assertEq((ONE_USDR + 1) * RATE / ONE_USDR, 541_700); // what floor would have given
    }

    function test_remainingFunding_tracksFunding() public {
        _fund(1_000 * ONE_USDC);
        assertEq(redemption.remainingFunding(), EXPECTED - 1_000 * ONE_USDC);
        _fund(redemption.remainingFunding());
        assertEq(redemption.remainingFunding(), 0);
    }

    function test_effectiveRate() public {
        assertEq(redemption.effectiveRate(), 0);

        _fund(EXPECTED / 4);
        assertEq(redemption.effectiveRate(), RATE / 4); // 135,425 = $0.135425

        _fund(EXPECTED - EXPECTED / 4);
        assertEq(redemption.effectiveRate(), RATE);
    }

    // -----------------------------------------------------------------
    // previewRedeem
    // -----------------------------------------------------------------

    function test_previewRedeem_isProRataNotRate() public {
        // Before funding nothing is payable, whatever the rate says.
        assertEq(redemption.previewRedeem(ONE_USDR), 0);

        // At 1% funding a whole USDR pays 1% of the rate: 5,417 raw USDC ($0.005417).
        _fund(EXPECTED / 100);
        assertEq(redemption.previewRedeem(ONE_USDR), 5_417);
        assertEq(redemption.previewRedeem(100_000 * ONE_USDR), 541_700_000); // $541.70

        // At full funding it pays the rate.
        _fund(redemption.remainingFunding());
        assertEq(redemption.previewRedeem(ONE_USDR), RATE);
    }

    function test_previewRedeem_roundsDown() public {
        _fund(EXPECTED / 100); // F/S = 5,417 raw USDC per whole USDR
        // 1 raw USDR unit (1e-9 USDR) previews to 0; the smallest amount paying 1 raw USDC unit
        // is ceil(1e9 / 5417) = 184,605 (184,604 * 5417 = 999,999,868 < 1e9).
        assertEq(redemption.previewRedeem(1), 0);
        assertEq(redemption.previewRedeem(184_604), 0);
        assertEq(redemption.previewRedeem(184_605), 1);
    }

    function test_previewRedeem_withPosition() public {
        _fund(EXPECTED / 10);
        _redeem(redemption, alice, 1_000 * ONE_USDR);

        // Nothing more is owed for the existing position...
        assertEq(redemption.previewRedeem(alice, 0), 0);
        assertEq(redemption.claimableUSDC(alice), 0);
        // ...and adding shares previews exactly what redeem would pay.
        uint256 preview = redemption.previewRedeem(alice, 500 * ONE_USDR);
        uint256 paid = _redeem(redemption, alice, 500 * ONE_USDR);
        assertEq(paid, preview);

        _fund(EXPECTED / 10);
        assertEq(redemption.previewRedeem(alice, 0), redemption.claimableUSDC(alice));
        assertGt(redemption.claimableUSDC(alice), 0);
    }

    // -----------------------------------------------------------------
    // redeem
    // -----------------------------------------------------------------

    function test_redeem_beforeFunding_registersSharesWithZeroPayout() public {
        _giveUsdr(alice, 100 * ONE_USDR);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Redeemed(alice, alice, 100 * ONE_USDR, 0);
        vm.prank(alice);
        uint256 paid = redemption.redeem(100 * ONE_USDR);

        assertEq(paid, 0);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdr.balanceOf(alice), 0); // burned regardless
        assertEq(usdr.totalSupply(), 0);
        assertEq(_shares(alice), 100 * ONE_USDR);
        assertEq(_paid(alice), 0);
        assertEq(redemption.totalShares(), 100 * ONE_USDR);
        assertEq(redemption.totalPaid(), 0);

        // The shares are worth something as soon as funding arrives.
        _fund(EXPECTED / 100);
        assertEq(redemption.claimableUSDC(alice), 100 * 5_417);
    }

    function test_redeem_proRata_happyPath() public {
        // 1% funded: 194,522.043184 USDC of the 19,452,204.3184 expected.
        _fund(EXPECTED / 100);
        _giveUsdr(alice, 100_000 * ONE_USDR);

        // floor(100_000e9 * 194_522_043_184 / 35_909_552e9) = 541_700_000 raw = $541.70, i.e. 1%
        // of the $54,170 this position is worth at full funding.
        uint256 expectedUsdc = 541_700_000;
        assertEq(expectedUsdc, _entitled(100_000 * ONE_USDR, EXPECTED / 100, TOTAL_SUPPLY));

        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Redeemed(alice, alice, 100_000 * ONE_USDR, expectedUsdc);
        vm.prank(alice);
        uint256 paid = redemption.redeem(100_000 * ONE_USDR);

        assertEq(paid, expectedUsdc);
        assertEq(usdc.balanceOf(alice), expectedUsdc);
        assertEq(usdr.balanceOf(alice), 0);
        assertEq(usdr.totalSupply(), 0); // burned, not transferred
        assertEq(usdr.balanceOf(address(redemption)), 0); // never custodied
        assertEq(usdr.allowance(alice, address(redemption)), 0); // allowance spent
        assertEq(_shares(alice), 100_000 * ONE_USDR);
        assertEq(_paid(alice), expectedUsdc);
        assertEq(redemption.totalPaid(), expectedUsdc);
        assertEq(redemption.availableUSDC(), EXPECTED / 100 - expectedUsdc);
    }

    /// @dev The worked example with the real deploy values: S = 35,909,552 USDR, R = $0.532.
    function test_redeem_workedExample_deployValues() public {
        USDRRedemption r = _deploy(532_000, TOTAL_SUPPLY);
        uint256 expected = 19_103_881_664_000; // $19,103,881.664

        // Tangible funds 1%: 191,038.81664 USDC. A 100,000 USDR holder gets 1% of $53,200 = $532.
        _fund(r, expected / 100);
        uint256 first = _redeem(r, alice, 100_000 * ONE_USDR);
        assertEq(first, 532 * ONE_USDC);

        // The rate is raised to $0.60: nothing changes until the money arrives...
        vm.prank(owner);
        r.setRate(600_000);
        assertEq(r.expectedFunding(), 21_545_731_200_000); // $21,545,731.20
        assertEq(r.claimableUSDC(alice), 0);

        // ...then the rest is funded to the penny and the holder's lifetime total is $60,000.
        _fund(r, r.remainingFunding());
        assertTrue(r.isFullyFunded());
        vm.prank(alice);
        uint256 second = r.claim();
        assertEq(first + second, 60_000 * ONE_USDC);
        assertEq(r.claimableUSDC(alice), 0);
    }

    function test_redeem_explicitReceiver() public {
        _fund(EXPECTED / 100);
        _giveUsdr(alice, 10 * ONE_USDR);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Redeemed(alice, bob, 10 * ONE_USDR, 54_170);
        vm.prank(alice);
        uint256 paid = redemption.redeem(10 * ONE_USDR, bob);

        assertEq(paid, 54_170);
        assertEq(usdc.balanceOf(bob), 54_170);
        assertEq(usdc.balanceOf(alice), 0);
        // The USDC goes to the receiver; the position stays with the redeemer.
        assertEq(_shares(alice), 10 * ONE_USDR);
        assertEq(_shares(bob), 0);
    }

    function test_redeem_zeroReceiverDefaultsToSender() public {
        _fund(EXPECTED / 100);
        _giveUsdr(alice, ONE_USDR);

        vm.prank(alice);
        redemption.redeem(ONE_USDR, address(0));

        assertEq(usdc.balanceOf(alice), 5_417);
    }

    function test_redeem_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IUSDRRedemption.ZeroAmount.selector);
        redemption.redeem(0);
    }

    function test_redeem_shareCap() public {
        // The whole configured supply can be presented...
        _redeem(redemption, alice, TOTAL_SUPPLY - 1);
        assertEq(redemption.maxRedeemableUSDR(), 1);

        // ...but not one raw unit more, even from another account: the pro-rata split
        // assumes the configured supply is the entire redeemable population.
        _giveUsdr(bob, 2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.ShareCapExceeded.selector, 2, 1));
        redemption.redeem(2);

        vm.prank(bob);
        redemption.redeem(1);
        assertEq(redemption.totalShares(), TOTAL_SUPPLY);
        assertEq(redemption.maxRedeemableUSDR(), 0);

        _giveUsdr(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.ShareCapExceeded.selector, 1, 0));
        redemption.redeem(1);
    }

    function test_redeem_revertsWithoutAllowance() public {
        _fund(EXPECTED / 100);
        usdr.mint(alice, ONE_USDR); // no approval

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(redemption), 0, ONE_USDR)
        );
        vm.prank(alice);
        redemption.redeem(ONE_USDR);
    }

    function test_redeem_revertsWhenUSDRPaused() public {
        _fund(EXPECTED / 100);
        _giveUsdr(alice, ONE_USDR);
        usdr.setPaused(true);

        // O-07: assert only that the burn branch reverts — not the mock's exact revert
        // string, which does not match the live USDR token. The real paused-token burn branch
        // is exercised end to end by test_fork_redeem_revertsWhenUSDRPaused in the fork suite.
        vm.expectRevert();
        vm.prank(alice);
        redemption.redeem(ONE_USDR);

        // Nothing was registered by the failed call.
        assertEq(_shares(alice), 0);
        assertEq(redemption.totalShares(), 0);
    }

    function test_redeem_noRaceForFunding() public {
        // Two equal holders at 1% funding: neither can take the other's slice, whatever the
        // order, and the pot still holds everyone else's.
        _fund(EXPECTED / 100);
        uint256 a = _redeem(redemption, alice, 100_000 * ONE_USDR);
        uint256 b = _redeem(redemption, bob, 100_000 * ONE_USDR);

        assertEq(a, b);
        assertEq(a, 541_700_000);
        assertEq(redemption.availableUSDC(), EXPECTED / 100 - 2 * a);
        assertGe(redemption.availableUSDC(), redemption.outstandingUSDC());
    }

    function test_redeem_multipleTranches_thenClaim() public {
        _fund(EXPECTED / 10);
        uint256 p1 = _redeem(redemption, alice, 1_000 * ONE_USDR);
        uint256 p2 = _redeem(redemption, alice, 2_000 * ONE_USDR);
        assertEq(_shares(alice), 3_000 * ONE_USDR);
        assertEq(p1 + p2, _entitled(3_000 * ONE_USDR, EXPECTED / 10, TOTAL_SUPPLY));

        _fund(EXPECTED / 10);
        vm.prank(alice);
        uint256 p3 = redemption.claim();
        assertEq(p1 + p2 + p3, _entitled(3_000 * ONE_USDR, EXPECTED / 5, TOTAL_SUPPLY));
    }

    /// @dev O-03: a malicious USDC that re-enters during the payout transfer must be stopped
    ///      by the nonReentrant guard — on both payout paths.
    function test_redeem_reentrancyGuarded() public {
        ReentrantUSDC evil = new ReentrantUSDC();
        USDRRedemption r = new USDRRedemption(address(usdr), address(evil), RATE, TOTAL_SUPPLY, owner);
        evil.setTarget(r);

        evil.mint(owner, 2_000 * ONE_USDC);
        vm.startPrank(owner);
        evil.approve(address(r), type(uint256).max);
        r.fund(1_000 * ONE_USDC);
        vm.stopPrank();

        usdr.mint(alice, 200_000 * ONE_USDR);
        vm.prank(alice);
        usdr.approve(address(r), 200_000 * ONE_USDR);

        evil.setAttack(ReentrantUSDC.Attack.Redeem);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        r.redeem(100_000 * ONE_USDR);

        // Register a position and fund more so claim has a payout to attack through. (The
        // revert rolled the mock's self-disarm back too, so disarm it explicitly.)
        evil.setAttack(ReentrantUSDC.Attack.None);
        vm.prank(alice);
        r.redeem(100_000 * ONE_USDR);
        vm.prank(owner);
        r.fund(1_000 * ONE_USDC);

        evil.setAttack(ReentrantUSDC.Attack.Claim);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        r.claim();
    }

    // -----------------------------------------------------------------
    // claim
    // -----------------------------------------------------------------

    function test_claim_afterLaterFunding() public {
        _fund(EXPECTED / 100);
        uint256 first = _redeem(redemption, alice, 100_000 * ONE_USDR);

        _fund(EXPECTED / 100); // now 2% funded
        uint256 owed = _entitled(100_000 * ONE_USDR, EXPECTED / 50, TOTAL_SUPPLY) - first;
        assertEq(redemption.claimableUSDC(alice), owed);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Claimed(alice, alice, owed);
        vm.prank(alice);
        uint256 paid = redemption.claim();

        assertEq(paid, owed);
        assertEq(usdc.balanceOf(alice), first + owed);
        assertEq(_paid(alice), first + owed);
        assertEq(redemption.totalPaid(), first + owed);
        assertEq(redemption.claimableUSDC(alice), 0);
    }

    function test_claim_revertsWhenNothingOwed() public {
        // No position at all.
        vm.prank(alice);
        vm.expectRevert(IUSDRRedemption.NothingToClaim.selector);
        redemption.claim();

        // A position that is already settled at the current funding level.
        _fund(EXPECTED / 100);
        _redeem(redemption, alice, 100_000 * ONE_USDR);
        vm.prank(alice);
        vm.expectRevert(IUSDRRedemption.NothingToClaim.selector);
        redemption.claim();
    }

    function test_claim_receiverRouting() public {
        _redeem(redemption, alice, 100_000 * ONE_USDR);
        _fund(EXPECTED / 100);

        vm.prank(alice);
        redemption.claim(bob);
        assertEq(usdc.balanceOf(bob), 541_700_000);
        assertEq(usdc.balanceOf(alice), 0);

        _fund(EXPECTED / 100);
        vm.prank(alice);
        redemption.claim(address(0)); // zero-coerced to the caller
        assertEq(usdc.balanceOf(alice), 541_700_000);
    }

    function test_claim_afterRateRaise() public {
        _fund(EXPECTED); // fully funded at $0.5417
        uint256 first = _redeem(redemption, alice, 100_000 * ONE_USDR);
        assertEq(first, 100_000 * RATE);

        // Raising the rate owes nothing by itself...
        vm.prank(owner);
        redemption.setRate(600_000);
        assertEq(redemption.claimableUSDC(alice), 0);
        vm.prank(alice);
        vm.expectRevert(IUSDRRedemption.NothingToClaim.selector);
        redemption.claim();

        // ...but every share, including already-redeemed ones, is worth more once funded.
        _fund(redemption.remainingFunding());
        vm.prank(alice);
        uint256 second = redemption.claim();
        assertEq(first + second, 100_000 * 600_000);
    }

    // -----------------------------------------------------------------
    // Rounding: nobody receives more or less for redeeming earlier or later
    // -----------------------------------------------------------------

    /// @dev A position's lifetime payout is floor(shares * F_final / S) regardless of how many
    ///      funding tranches arrive, when it was presented, or which intermediate claims it made.
    function testFuzz_rounding_pathIndependence(uint256 shares, uint256[8] memory tranches, uint8 redeemAt, uint8 mask)
        public
    {
        shares = bound(shares, 1, TOTAL_SUPPLY);
        redeemAt = uint8(bound(redeemAt, 0, 8));

        if (redeemAt == 0) _redeem(redemption, alice, shares);
        for (uint256 i = 0; i < 8; i++) {
            uint256 remaining = redemption.remainingFunding();
            uint256 amount = bound(tranches[i], 0, remaining);
            if (amount != 0) _fund(amount);
            if (redeemAt == i + 1) _redeem(redemption, alice, shares);
            else if (redeemAt <= i && (mask >> i) & 1 == 1) _claimIfAny(redemption, alice);
        }
        _claimIfAny(redemption, alice);

        uint256 fundedFinal = redemption.totalFunded();
        assertEq(usdc.balanceOf(alice), _entitled(shares, fundedFinal, TOTAL_SUPPLY), "lifetime payout");
        assertEq(redemption.claimableUSDC(alice), 0);
        assertEq(_paid(alice), usdc.balanceOf(alice));
    }

    /// @dev Presenting USDR in several tranches at different funding levels yields exactly the
    ///      same lifetime payout as presenting the total once.
    function testFuzz_rounding_trancheIndependence(
        uint256 total,
        uint256 cut1,
        uint256 cut2,
        uint256[3] memory fundings
    ) public {
        total = bound(total, 3, TOTAL_SUPPLY);
        cut1 = bound(cut1, 1, total - 2);
        cut2 = bound(cut2, cut1 + 1, total - 1);
        uint256[3] memory parts = [cut1, cut2 - cut1, total - cut2];

        USDRRedemption a = _deploy(RATE, TOTAL_SUPPLY);
        USDRRedemption b = _deploy(RATE, TOTAL_SUPPLY);

        for (uint256 i = 0; i < 3; i++) {
            uint256 amount = bound(fundings[i], 0, a.remainingFunding());
            if (amount != 0) {
                _fund(a, amount);
                _fund(b, amount);
            }
            _redeem(a, alice, parts[i]); // tranche by tranche...
        }
        _redeem(b, bob, total); // ...versus all at once, at the end.
        _claimIfAny(a, alice);

        assertEq(usdc.balanceOf(alice), usdc.balanceOf(bob), "tranches vs single shot");
        assertEq(usdc.balanceOf(bob), _entitled(total, b.totalFunded(), TOTAL_SUPPLY));
    }

    /// @dev Whether Alice or Bob goes first changes nothing for either of them.
    function testFuzz_rounding_orderIndependence(uint256 sa, uint256 sb, uint256 f1, uint256 f2) public {
        sa = bound(sa, 1, TOTAL_SUPPLY / 2);
        sb = bound(sb, 1, TOTAL_SUPPLY / 2);
        f1 = bound(f1, 0, EXPECTED);
        f2 = bound(f2, 0, EXPECTED - f1);

        USDRRedemption a = _deploy(RATE, TOTAL_SUPPLY);
        USDRRedemption b = _deploy(RATE, TOTAL_SUPPLY);
        if (f1 != 0) {
            _fund(a, f1);
            _fund(b, f1);
        }

        uint256 aliceA = _redeem(a, alice, sa);
        uint256 bobA = _redeem(a, bob, sb);
        uint256 bobB = _redeem(b, carol, sb); // bob's amount, going first this time
        uint256 aliceB = _redeem(b, makeAddr("dave"), sa);

        if (f2 != 0) {
            _fund(a, f2);
            _fund(b, f2);
        }
        aliceA += _claimIfAny(a, alice);
        bobA += _claimIfAny(a, bob);
        bobB += _claimIfAny(b, carol);
        aliceB += _claimIfAny(b, makeAddr("dave"));

        assertEq(aliceA, aliceB, "alice independent of order");
        assertEq(bobA, bobB, "bob independent of order");
        assertEq(aliceA, _entitled(sa, f1 + f2, TOTAL_SUPPLY));
        assertEq(bobA, _entitled(sb, f1 + f2, TOTAL_SUPPLY));
    }

    /// @dev Splitting a holding across wallets can never gain; it can lose at most 1 raw unit
    ///      ($0.000001) per extra wallet to flooring.
    function testFuzz_rounding_walletSplitNeverGains(uint256 sa, uint256 sb, uint256 funding) public {
        // Both scenarios run in the same contract, so together they must fit the share cap.
        sa = bound(sa, 1, TOTAL_SUPPLY / 4);
        sb = bound(sb, 1, TOTAL_SUPPLY / 4);
        funding = bound(funding, 1, EXPECTED);
        _fund(funding);

        uint256 single = _redeem(redemption, alice, sa + sb);
        uint256 split = _redeem(redemption, bob, sa) + _redeem(redemption, carol, sb);

        assertGe(single, split, "split must never gain");
        assertLe(single - split, 1, "split loses at most one raw unit");
    }

    /// @dev At full funding every holder receives the nominal rate, floor-rounded, exactly —
    ///      the ceil in expectedFunding guarantees the "never less" half for any supply.
    function testFuzz_rounding_fullFundingPaysNominalRate(uint256 shares) public {
        shares = bound(shares, 1, TOTAL_SUPPLY);
        _fund(EXPECTED);
        uint256 paid = _redeem(redemption, alice, shares);
        assertEq(paid, (shares * RATE) / ONE_USDR);
    }

    function testFuzz_rounding_fullFundingNeverBelowNominal(uint256 supply, uint256 shares) public {
        // An arbitrary (non-whole) supply, where expectedFunding's ceil matters.
        supply = bound(supply, 1, TOTAL_SUPPLY);
        shares = bound(shares, 1, supply);
        USDRRedemption r = _deploy(RATE, supply);
        _fund(r, r.expectedFunding());

        uint256 paid = _redeem(r, alice, shares);
        uint256 nominal = (shares * RATE) / ONE_USDR;
        assertGe(paid, nominal, "never below the rate");
        assertLe(paid - nominal, 1, "at most one raw unit above");
    }

    /// @dev After any sequence the contract can always pay everything it owes.
    function testFuzz_rounding_solvency(uint256[3] memory shares, uint256[3] memory fundings) public {
        address[3] memory who = [alice, bob, carol];
        uint256 sumOwed;
        for (uint256 i = 0; i < 3; i++) {
            uint256 amount = bound(fundings[i], 0, redemption.remainingFunding());
            if (amount != 0) _fund(amount);
            _redeem(redemption, who[i], bound(shares[i], 1, TOTAL_SUPPLY / 3));
        }
        for (uint256 i = 0; i < 3; i++) {
            sumOwed += redemption.claimableUSDC(who[i]);
        }
        assertLe(redemption.totalPaid(), redemption.totalFunded());
        assertLe(sumOwed, redemption.outstandingUSDC());
        assertGe(redemption.availableUSDC(), redemption.totalFunded() - redemption.totalPaid());
        assertGe(redemption.availableUSDC(), sumOwed);

        for (uint256 i = 0; i < 3; i++) {
            _claimIfAny(redemption, who[i]); // and paying it never reverts
        }
    }

    // -----------------------------------------------------------------
    // fund
    // -----------------------------------------------------------------

    function test_fund_pullsAndTracks() public {
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Funded(owner, 500 * ONE_USDC, 500 * ONE_USDC);
        _fund(500 * ONE_USDC);

        assertEq(redemption.availableUSDC(), 500 * ONE_USDC);
        assertEq(redemption.totalFunded(), 500 * ONE_USDC);
        assertEq(redemption.remainingFunding(), EXPECTED - 500 * ONE_USDC);
        assertEq(redemption.fullyFundedAt(), 0); // partial funding starts no clock
        assertEq(redemption.sweepUnlockTime(), type(uint256).max);

        _fund(500 * ONE_USDC);
        assertEq(redemption.totalFunded(), 1_000 * ONE_USDC);
    }

    function test_fund_toThePenny_startsTheClock() public {
        // Over-funding is rejected with the exact remainder in the error...
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.FundingExceedsExpected.selector, EXPECTED + 1, EXPECTED));
        redemption.fund(EXPECTED + 1);

        _fund(EXPECTED - 5);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.FundingExceedsExpected.selector, 6, 5));
        redemption.fund(6);
        assertEq(redemption.remainingFunding(), 5);
        assertFalse(redemption.isFullyFunded());

        // ...and the final penny stamps full funding and schedules the sweep.
        uint256 t = block.timestamp;
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.FullyFunded(t + 180 days);
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Funded(owner, 5, EXPECTED);
        _fund(5);

        assertTrue(redemption.isFullyFunded());
        assertEq(redemption.fullyFundedAt(), t);
        assertEq(redemption.sweepUnlockTime(), t + 180 days);
        assertEq(redemption.remainingFunding(), 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.FundingExceedsExpected.selector, 1, 0));
        redemption.fund(1);
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
        vm.expectRevert(IUSDRRedemption.ZeroAmount.selector);
        redemption.fund(0);
    }

    function test_fund_revertsWithoutUSDCAllowance() public {
        vm.startPrank(owner);
        usdc.approve(address(redemption), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(redemption), 0, ONE_USDC)
        );
        redemption.fund(ONE_USDC);
        vm.stopPrank();
    }

    function test_rawTransferIsNotFunding() public {
        _redeem(redemption, alice, 100_000 * ONE_USDR);

        usdc.mint(bob, 5 * ONE_USDC);
        vm.prank(bob);
        usdc.transfer(address(redemption), 5 * ONE_USDC);

        // Sits in the balance, but is owed to nobody and does not count towards full funding.
        assertEq(redemption.availableUSDC(), 5 * ONE_USDC);
        assertEq(redemption.totalFunded(), 0);
        assertEq(redemption.remainingFunding(), EXPECTED);
        assertEq(redemption.claimableUSDC(alice), 0);
        assertEq(redemption.outstandingUSDC(), 0);
    }

    function test_fund_revertsUnlessExactAmountIsReceived() public {
        ShortTransferUSDC short = new ShortTransferUSDC();
        USDRRedemption r = new USDRRedemption(address(usdr), address(short), RATE, TOTAL_SUPPLY, owner);
        short.mint(owner, ONE_USDC);
        vm.startPrank(owner);
        short.approve(address(r), ONE_USDC);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.FundingReceiptMismatch.selector, ONE_USDC, ONE_USDC - 1));
        r.fund(ONE_USDC);
        vm.stopPrank();

        // The failed receipt check rolls the token transfer and ledger update back together.
        assertEq(short.balanceOf(owner), ONE_USDC);
        assertEq(short.balanceOf(address(r)), 0);
        assertEq(r.totalFunded(), 0);
    }

    function test_fundFromBalance_recognizesAccidentalTransfer() public {
        _redeem(redemption, alice, 100_000 * ONE_USDR);
        usdc.mint(address(redemption), 5 * ONE_USDC);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.ExistingFundingRecognized(owner, 5 * ONE_USDC, 5 * ONE_USDC);
        vm.prank(owner);
        redemption.fundFromBalance(5 * ONE_USDC);

        assertEq(redemption.totalFunded(), 5 * ONE_USDC);
        assertEq(redemption.availableUSDC(), 5 * ONE_USDC);
        assertEq(redemption.remainingFunding(), EXPECTED - 5 * ONE_USDC);
        assertGt(redemption.claimableUSDC(alice), 0);
    }

    function test_fundFromBalance_onlyUsesUnaccountedReserve() public {
        _fund(5 * ONE_USDC);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.InsufficientUnaccountedUSDC.selector, 1, 0));
        redemption.fundFromBalance(1);

        usdc.mint(address(redemption), 7);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.InsufficientUnaccountedUSDC.selector, 8, 7));
        redemption.fundFromBalance(8);
    }

    function test_fundFromBalance_enforcesFundingCapAndAccess() public {
        usdc.mint(address(redemption), EXPECTED + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        redemption.fundFromBalance(1);

        vm.prank(owner);
        vm.expectRevert(IUSDRRedemption.ZeroAmount.selector);
        redemption.fundFromBalance(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.FundingExceedsExpected.selector, EXPECTED + 1, EXPECTED));
        redemption.fundFromBalance(EXPECTED + 1);
    }

    function test_fundFromBalance_canFullyFundAndStartClock() public {
        usdc.mint(address(redemption), EXPECTED);
        uint256 t = block.timestamp;

        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.FullyFunded(t + 180 days);
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.ExistingFundingRecognized(owner, EXPECTED, EXPECTED);
        vm.prank(owner);
        redemption.fundFromBalance(EXPECTED);

        assertTrue(redemption.isFullyFunded());
        assertEq(redemption.fullyFundedAt(), t);
        assertEq(redemption.sweepUnlockTime(), t + 180 days);
    }

    // -----------------------------------------------------------------
    // setRate
    // -----------------------------------------------------------------

    function test_setRate_raises() public {
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.RateUpdated(RATE, 600_000);
        vm.prank(owner);
        redemption.setRate(600_000);

        assertEq(redemption.rate(), 600_000);
        assertEq(redemption.expectedFunding(), 35_909_552 * 600_000);
        assertEq(redemption.remainingFunding(), 35_909_552 * 600_000);
    }

    function test_setRate_revertsUnlessIncreasing() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.RateNotIncreasing.selector, RATE, RATE));
        redemption.setRate(RATE);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.RateNotIncreasing.selector, RATE, RATE - 1));
        redemption.setRate(RATE - 1);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.RateNotIncreasing.selector, RATE, 0));
        redemption.setRate(0);
        vm.stopPrank();
        assertEq(redemption.rate(), RATE);
    }

    function test_setRate_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        redemption.setRate(600_000);
    }

    function test_setRate_revertsOnExpectedFundingOverflow() public {
        // 35.9M USDR at a rate of 2^128 raw USDC per USDR overflows the uint128 `paid` bound.
        vm.prank(owner);
        vm.expectRevert(IUSDRRedemption.ConfigOverflow.selector);
        redemption.setRate(uint256(type(uint128).max) + 1);
    }

    function test_setRate_neverClawsBack() public {
        _fund(EXPECTED / 2);
        uint256 first = _redeem(redemption, alice, 100_000 * ONE_USDR);

        vm.prank(owner);
        redemption.setRate(RATE * 2);

        // The position is untouched; the payout so far stands; nothing is owed until funded.
        assertEq(_paid(alice), first);
        assertEq(redemption.claimableUSDC(alice), 0);
        assertEq(usdc.balanceOf(alice), first);

        // A quarter of the new expectation: the old F is now a quarter of the way there.
        assertEq(redemption.effectiveRate(), RATE / 2);
    }

    function test_setRate_clearsFullFundingAndRearms() public {
        _fund(EXPECTED);
        uint256 t0 = block.timestamp;
        assertEq(redemption.fullyFundedAt(), t0);

        vm.warp(t0 + 100 days);
        vm.prank(owner);
        redemption.setRate(600_000);

        // No longer fully funded: the countdown is cancelled outright.
        assertFalse(redemption.isFullyFunded());
        assertEq(redemption.fullyFundedAt(), 0);
        assertEq(redemption.sweepUnlockTime(), type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, type(uint256).max));
        redemption.sweep(owner);

        // Topping up to the new expectation re-arms it from scratch.
        vm.warp(t0 + 200 days);
        _fund(redemption.remainingFunding());
        assertEq(redemption.fullyFundedAt(), t0 + 200 days);
        assertEq(redemption.sweepUnlockTime(), t0 + 380 days);
    }

    function test_setRate_keepsFullFundingWhenCeilingUnchanged() public {
        // With a supply below one whole USDR a tiny raise may not move the (ceil'd) funding
        // target at all, so the contract must stay fully funded rather than getting stuck
        // with fullyFundedAt == 0 and no way to fund the (zero) remainder.
        USDRRedemption r = _deploy(RATE, 1); // 1 raw USDR: expectedFunding = ceil(541700 / 1e9) = 1
        assertEq(r.expectedFunding(), 1);
        _fund(r, 1);
        uint256 t = block.timestamp;
        assertEq(r.fullyFundedAt(), t);

        vm.prank(owner);
        r.setRate(RATE + 1);
        assertEq(r.expectedFunding(), 1);
        assertEq(r.fullyFundedAt(), t);
        assertTrue(r.isFullyFunded());
        assertEq(r.remainingFunding(), 0);
    }

    // -----------------------------------------------------------------
    // sweep
    // -----------------------------------------------------------------

    function test_sweep_lockedWhileUnderfunded() public {
        _fund(EXPECTED - 1);
        vm.warp(block.timestamp + 10 * 365 days); // no amount of waiting helps

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, type(uint256).max));
        redemption.sweep(owner);
    }

    function test_sweep_lockedFor180DaysAfterFullFunding() public {
        vm.warp(block.timestamp + 30 days);
        _fund(EXPECTED);
        uint256 unlock = block.timestamp + 180 days;
        assertEq(redemption.sweepUnlockTime(), unlock);

        vm.warp(unlock - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, unlock));
        redemption.sweep(owner);

        vm.warp(unlock);
        vm.prank(owner);
        redemption.sweep(bob);
        assertEq(usdc.balanceOf(bob), EXPECTED);
    }

    function test_sweep_takesEverythingAndCloses() public {
        // Alice presented at 50% and never came back for the rest; Carol never presented;
        // someone also sent 7 USDC by raw transfer.
        _fund(EXPECTED / 2);
        uint256 alicePaid = _redeem(redemption, alice, 100_000 * ONE_USDR);
        _fund(redemption.remainingFunding());
        usdc.mint(address(redemption), 7 * ONE_USDC);

        uint256 outstanding = redemption.outstandingUSDC();
        assertEq(outstanding, redemption.claimableUSDC(alice));
        assertGt(outstanding, 0);
        uint256 balance = redemption.availableUSDC();
        assertEq(balance, EXPECTED - alicePaid + 7 * ONE_USDC);

        vm.warp(redemption.sweepUnlockTime());
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Closed();
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Swept(bob, balance);
        vm.prank(owner);
        redemption.sweep(bob);

        // Everything — Alice's unclaimed remainder included — is gone, and the contract is shut.
        assertEq(usdc.balanceOf(bob), balance);
        assertEq(redemption.availableUSDC(), 0);
        assertTrue(redemption.closed());
        assertEq(redemption.maxRedeemableUSDR(), 0);
        assertEq(redemption.previewRedeem(ONE_USDR), 0);
        assertEq(redemption.previewRedeem(alice, ONE_USDR), 0);
        assertEq(redemption.claimableUSDC(alice), 0);
        assertEq(redemption.outstandingUSDC(), 0);

        vm.prank(alice);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.claim();

        _giveUsdr(carol, ONE_USDR);
        vm.prank(carol);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.redeem(ONE_USDR);

        vm.startPrank(owner);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.fund(1);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.setRate(RATE + 1);
        vm.stopPrank();
    }

    function test_sweep_againAfterClose_recoversLateUSDC() public {
        _fund(EXPECTED);
        vm.warp(redemption.sweepUnlockTime());
        vm.prank(owner);
        redemption.sweep(owner);
        assertTrue(redemption.closed());

        // USDC that lands after the close is still recoverable, with no timelock in the way.
        usdc.mint(address(redemption), 3 * ONE_USDC);
        vm.prank(owner);
        redemption.sweep(bob);
        assertEq(usdc.balanceOf(bob), 3 * ONE_USDC);
        assertEq(redemption.availableUSDC(), 0);
    }

    function test_sweep_revertsForNonOwner() public {
        _fund(EXPECTED);
        vm.warp(redemption.sweepUnlockTime());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        redemption.sweep(alice);
    }

    function test_sweep_revertsOnZeroAddress() public {
        _fund(EXPECTED);
        vm.warp(redemption.sweepUnlockTime());
        vm.prank(owner);
        vm.expectRevert(IUSDRRedemption.ZeroAddress.selector);
        redemption.sweep(address(0));
    }

    function test_sweep_zeroBalanceStillCloses() public {
        // Everyone presented and claimed everything. There is no value to move, but the
        // terminal lifecycle transition must still be reachable.
        _fund(EXPECTED);
        _redeem(redemption, alice, TOTAL_SUPPLY);
        assertEq(redemption.availableUSDC(), 0);

        vm.warp(redemption.sweepUnlockTime());
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Closed();
        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Swept(bob, 0);
        vm.prank(owner);
        redemption.sweep(bob);
        assertTrue(redemption.closed());

        // An empty follow-up sweep remains a clear failed operation.
        vm.prank(owner);
        vm.expectRevert(IUSDRRedemption.ZeroAmount.selector);
        redemption.sweep(bob);
    }

    // -----------------------------------------------------------------
    // rescueERC20
    // -----------------------------------------------------------------

    function test_rescue_straysRecovered() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(redemption), 42e6);

        vm.expectEmit(true, true, true, true, address(redemption));
        emit IUSDRRedemption.Rescued(address(stray), bob, 42e6);
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
        vm.expectRevert(IUSDRRedemption.CannotRescueUSDC.selector);
        redemption.rescueERC20(address(usdc), owner);
    }

    function test_rescue_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        redemption.rescueERC20(address(usdr), alice);
    }

    function test_rescue_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IUSDRRedemption.ZeroAddress.selector);
        redemption.rescueERC20(address(usdr), address(0));
    }

    function test_rescue_zeroBalanceReverts() public {
        // O-30: rescuing a token the contract holds none of reverts with ZeroAmount, so a
        // mistyped or already-rescued token address fails clearly instead of no-opping.
        MockUSDC stray = new MockUSDC();
        vm.prank(owner);
        vm.expectRevert(IUSDRRedemption.ZeroAmount.selector);
        redemption.rescueERC20(address(stray), bob);
        assertEq(stray.balanceOf(bob), 0);

        // With a balance present the rescue still succeeds, and rescuing twice reverts.
        stray.mint(address(redemption), 42e6);
        vm.startPrank(owner);
        redemption.rescueERC20(address(stray), bob);
        assertEq(stray.balanceOf(bob), 42e6);

        vm.expectRevert(IUSDRRedemption.ZeroAmount.selector);
        redemption.rescueERC20(address(stray), bob);
        vm.stopPrank();
    }

    function test_rescue_stillWorksAfterClose() public {
        _fund(EXPECTED);
        vm.warp(redemption.sweepUnlockTime());
        vm.prank(owner);
        redemption.sweep(owner);

        usdr.mint(address(redemption), ONE_USDR);
        vm.prank(owner);
        redemption.rescueERC20(address(usdr), alice);
        assertEq(usdr.balanceOf(alice), ONE_USDR);
    }

    // -----------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------

    function test_views_outstandingBoundsClaimable() public {
        _fund(EXPECTED / 3); // a non-round fraction so per-account flooring shows up
        _redeem(redemption, alice, 7);
        _redeem(redemption, bob, 11);
        _redeem(redemption, carol, 13);
        _fund(EXPECTED / 7);

        uint256 sum = redemption.claimableUSDC(alice) + redemption.claimableUSDC(bob) + redemption.claimableUSDC(carol);
        assertLe(sum, redemption.outstandingUSDC());
        assertLe(redemption.outstandingUSDC() - sum, 2); // at most one raw unit per extra account
    }

    function test_views_maxRedeemableTracksShares() public {
        assertEq(redemption.maxRedeemableUSDR(), TOTAL_SUPPLY);
        _redeem(redemption, alice, 1_000 * ONE_USDR);
        assertEq(redemption.maxRedeemableUSDR(), TOTAL_SUPPLY - 1_000 * ONE_USDR);
    }

    /// @dev O-26: vary the receiver through the two-arg overload; payout must land at the
    ///      resolved receiver (address(0) -> msg.sender).
    function testFuzz_redeem_receiverRouting(address receiver, uint256 usdrAmount) public {
        vm.assume(receiver != owner && receiver != address(redemption));
        vm.assume(usdc.balanceOf(receiver) == 0);
        usdrAmount = bound(usdrAmount, ONE_USDR, 1e6 * ONE_USDR);
        _fund(EXPECTED / 100);
        _giveUsdr(alice, usdrAmount);

        uint256 payout = redemption.previewRedeem(usdrAmount);
        assertGt(payout, 0);
        vm.prank(alice);
        redemption.redeem(usdrAmount, receiver);

        address resolved = receiver == address(0) ? alice : receiver;
        assertEq(usdc.balanceOf(resolved), payout, "payout must land at the resolved receiver");
        if (resolved != alice) assertEq(usdc.balanceOf(alice), 0, "redeemer must not be paid");
        assertEq(_shares(alice), usdrAmount, "shares stay with the redeemer");
    }

    /// @dev O-27: the funding math must hold for any rate and supply, not just the fixture's.
    function testFuzz_expectedFunding_parameterized(uint256 rate_, uint256 supply) public {
        rate_ = bound(rate_, 1, 1e12);
        supply = bound(supply, 1, type(uint128).max / 1e12);
        USDRRedemption r = _deploy(rate_, supply);

        uint256 expected = r.expectedFunding();
        uint256 product = supply * rate_;
        // ceil: the smallest value whose scaled form covers the product.
        assertGe(expected * ONE_USDR, product);
        assertLt((expected - 1) * ONE_USDR, product);
    }

    /// @dev O-21: I4 — user gas is O(1). A redeem after a long fund/redeem history costs the
    ///      same as a fresh one (one position slot, no history replay).
    function test_redeem_gasConstantAcrossHistory() public {
        _giveUsdr(alice, 1_000 * ONE_USDR);
        _fund(1_000 * ONE_USDC);

        // Warm up storage/accounts so the baseline excludes one-time cold-access costs.
        vm.prank(alice);
        redemption.redeem(ONE_USDR);

        _fund(1_000 * ONE_USDC);
        vm.prank(alice);
        uint256 g = gasleft();
        redemption.redeem(ONE_USDR);
        uint256 baseline = g - gasleft();

        for (uint256 i = 0; i < 50; i++) {
            _fund(1_000 * ONE_USDC);
            vm.warp(block.timestamp + 1 days);
            vm.prank(alice);
            redemption.redeem(ONE_USDR);
        }

        _fund(1_000 * ONE_USDC);
        vm.prank(alice);
        g = gasleft();
        redemption.redeem(ONE_USDR);
        uint256 laterCost = g - gasleft();

        assertApproxEqAbs(laterCost, baseline, 200, "redeem gas grew with history");
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        redemption.setRate(RATE + 1);
    }

    function test_ownership_renounceDisabled() public {
        // Renouncing would strand the reserve: no fund(), no setRate(), no sweep(), no
        // rescueERC20(), and no way back to an owner.
        vm.prank(owner);
        vm.expectRevert(IUSDRRedemption.RenounceOwnershipDisabled.selector);
        redemption.renounceOwnership();

        assertEq(redemption.owner(), owner);

        // Still reverts for a non-owner, and the owner keeps every gated path.
        vm.prank(alice);
        vm.expectRevert(IUSDRRedemption.RenounceOwnershipDisabled.selector);
        redemption.renounceOwnership();

        _fund(100 * ONE_USDC);
        assertEq(redemption.availableUSDC(), 100 * ONE_USDC);
    }
}
