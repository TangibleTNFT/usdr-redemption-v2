// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {USDRRedemption} from "../../src/USDRRedemption.sol";
import {IUSDRRedemption} from "../../src/interfaces/IUSDRRedemption.sol";

interface IUSDRToken is IERC20 {
    function burn(address account, uint256 amount) external;
    function paused() external view returns (bool);
}

/// @notice Minimal native Circle FiatToken surface for driving its blacklist path on a fork.
/// @dev Bridged USDC.e uses AccessControl, reports zero BLACKLISTER_ROLE members at the pinned
///      block and cannot exercise this path.
interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

/// @notice Polygon fork integration tests: redeem REAL USDR end to end against the live
///         token (allowance-based burn), parameterized over the USDC
///         flavour via {_usdcToken}. Run with POLYGON_RPC_URL set, or fall back to a
///         public endpoint (https://chainlist.org/rpcs.json).
abstract contract USDRRedemptionForkTestBase is Test {
    // Live Polygon addresses.
    address internal constant USDR = 0x40379a439D4F6795B6fc9aa5687dB461677A2dBa;
    address internal constant NATIVE_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant BRIDGED_USDCE = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    /// Largest non-contract USDR holder (~4.1M USDR), impersonated as the redeemer.
    address internal constant HOLDER = 0x7C4D2Fe416a71F549188a3812F73Cac99b7BFB75;

    // Public archive endpoint (from https://chainlist.org/rpcs.json); most other public
    // Polygon RPCs are pruned and cannot serve state at a pinned block.
    string internal constant FALLBACK_RPC = "https://polygon.drpc.org";
    uint256 internal constant FORK_BLOCK = 88_250_000; // pinned for determinism + RPC caching

    uint256 internal constant RATE = 541_700; // $0.5417 placeholder, non-round on purpose
    uint256 internal constant ONE_USDR = 1e9;
    uint256 internal constant FUNDING = 1_000_000e6; // 1M USDC: a partial first tranche
    uint256 internal constant PRODUCTION_TOTAL_SUPPLY = 35_909_552e9;

    USDRRedemption internal redemption;
    IUSDRToken internal usdr = IUSDRToken(USDR);
    IERC20 internal usdc;

    /// @dev The production accessible-supply denominator, not the token's larger totalSupply.
    uint256 internal totalSupply;

    address internal owner = makeAddr("safeOwner");

    /// @dev Concrete suites pick native USDC or bridged USDC.e.
    function _usdcToken() internal pure virtual returns (address);

    function setUp() public {
        vm.createSelectFork(vm.envOr("POLYGON_RPC_URL", FALLBACK_RPC), FORK_BLOCK);
        usdc = IERC20(_usdcToken());
        totalSupply = PRODUCTION_TOTAL_SUPPLY;

        redemption = new USDRRedemption(USDR, _usdcToken(), RATE, totalSupply, owner);
        assertGt(redemption.expectedFunding(), FUNDING, "fixture: first tranche should be partial");

        // Tangible funds a first tranche: give the owner USDC and fund() through the
        // explicit entrypoint, as in production.
        _fund(FUNDING);

        assertFalse(usdr.paused(), "USDR token is paused on this fork");
    }

    function _fund(uint256 amount) internal {
        deal(_usdcToken(), owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(redemption), amount);
        redemption.fund(amount);
        vm.stopPrank();
    }

    /// @dev Independently computed pro-rata payout: floor(amount * funded / supply).
    function _proRata(uint256 usdrAmount) internal view returns (uint256) {
        return (usdrAmount * redemption.totalFunded()) / totalSupply;
    }

    function test_fork_redeem_realUSDR_endToEnd() public {
        uint256 redeemAmount = 10_000 * ONE_USDR;
        uint256 holderUsdrBefore = usdr.balanceOf(HOLDER);
        uint256 holderUsdcBefore = usdc.balanceOf(HOLDER);
        uint256 supplyBefore = usdr.totalSupply();
        assertGe(holderUsdrBefore, redeemAmount, "holder no longer has enough USDR");

        uint256 expectedUsdc = _proRata(redeemAmount);
        assertGt(expectedUsdc, 0);
        assertLt(expectedUsdc, (redeemAmount * RATE) / ONE_USDR, "partial funding pays below the rate");

        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), redeemAmount);
        uint256 paid = redemption.redeem(redeemAmount);
        vm.stopPrank();

        assertEq(paid, expectedUsdc);
        assertEq(usdc.balanceOf(HOLDER) - holderUsdcBefore, expectedUsdc);
        assertEq(usdc.balanceOf(address(redemption)), FUNDING - expectedUsdc);
        (uint256 shares, uint256 paidOut) = redemption.positions(HOLDER);
        assertEq(shares, redeemAmount);
        assertEq(paidOut, expectedUsdc);
        // Although rebasing is disabled, USDR retains its legacy indexed/ray balance
        // representation, so burn deltas can carry a ~1-unit (1e-9 USDR) rounding wobble.
        assertApproxEqAbs(usdr.balanceOf(HOLDER), holderUsdrBefore - redeemAmount, 2);
        assertApproxEqAbs(usdr.totalSupply(), supplyBefore - redeemAmount, 2);
        // Burned from the holder, never custodied by the contract.
        assertEq(usdr.balanceOf(address(redemption)), 0);
        assertEq(usdr.allowance(HOLDER, address(redemption)), 0);
    }

    function test_fork_redeem_toExplicitReceiver() public {
        address receiver = makeAddr("receiver");
        uint256 redeemAmount = 1_000 * ONE_USDR;

        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), redeemAmount);
        redemption.redeem(redeemAmount, receiver);
        vm.stopPrank();

        assertEq(usdc.balanceOf(receiver), _proRata(redeemAmount));
        (uint256 shares,) = redemption.positions(HOLDER);
        assertEq(shares, redeemAmount);
    }

    function test_fork_redeem_revertsWithoutApproval() public {
        uint256 redeemAmount = 1_000 * ONE_USDR;
        // O-08: pin the revert to the missing-approval path. With the holder holding enough
        // USDR and zero allowance, the only thing that can make redeem revert is the
        // allowance-spend in burn — so the (token-version-specific) revert reason need not
        // be hardcoded.
        assertEq(usdr.allowance(HOLDER, address(redemption)), 0, "fixture: allowance must be 0");
        assertGe(usdr.balanceOf(HOLDER), redeemAmount, "fixture: holder needs the USDR");

        vm.prank(HOLDER);
        vm.expectRevert(); // real USDR: allowance spend underflows/reverts
        redemption.redeem(redeemAmount);
    }

    function test_fork_redeem_dustRegistersWithZeroPayout() public {
        // 1e-9 USDR is worth less than one raw USDC unit at this funding level; it is still
        // burned and registered (no revert), and simply pays nothing yet.
        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), 1);
        uint256 paid = redemption.redeem(1);
        vm.stopPrank();

        assertEq(paid, 0);
        (uint256 shares,) = redemption.positions(HOLDER);
        assertEq(shares, 1);
    }

    function test_fork_redeem_fullPositionIsProRata_noRace() public {
        // The holder's full position (~4.1M USDR, ~2.2M USDC at the rate) far exceeds the 1M
        // first tranche, yet redeeming it neither reverts nor drains the pot: it pays exactly
        // the holder's share of what has been funded.
        uint256 holderBalance = usdr.balanceOf(HOLDER);
        assertGt((holderBalance * RATE) / ONE_USDR, FUNDING, "fixture: position should exceed funding");
        uint256 expected = _proRata(holderBalance);

        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), holderBalance);
        uint256 paid = redemption.redeem(holderBalance);
        vm.stopPrank();

        assertEq(paid, expected);
        assertGt(redemption.availableUSDC(), 0, "pot must not be drained by one holder");
        assertGe(redemption.availableUSDC(), redemption.outstandingUSDC());
    }

    function test_fork_claim_afterTopUp() public {
        uint256 redeemAmount = 10_000 * ONE_USDR;
        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), redeemAmount);
        uint256 first = redemption.redeem(redeemAmount);
        vm.stopPrank();

        _fund(FUNDING); // second tranche
        uint256 owed = _proRata(redeemAmount) - first;
        assertEq(redemption.claimableUSDC(HOLDER), owed);

        vm.prank(HOLDER);
        uint256 second = redemption.claim();
        assertEq(second, owed);
        assertEq(first + second, _proRata(redeemAmount));
    }

    /// @dev O-28: a USDC-side failure (receiver blacklisted) must revert the whole redeem,
    ///      rolling back the USDR burn and the position. Exercises the external-token
    ///      failure path on the live FiatToken.
    function _assertRedeemRevertsWhenReceiverBlacklisted() internal {
        address receiver = makeAddr("blacklistedReceiver");
        uint256 redeemAmount = 1_000 * ONE_USDR;

        IFiatToken token = IFiatToken(_usdcToken());
        address blacklister = token.blacklister();
        vm.prank(blacklister);
        token.blacklist(receiver);

        uint256 supplyBefore = usdr.totalSupply();
        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), redeemAmount);
        vm.expectRevert(); // FiatToken: transfer to a blacklisted account reverts
        redemption.redeem(redeemAmount, receiver);
        vm.stopPrank();

        // The burn and the share registration were rolled back with the failed payout.
        assertEq(usdr.totalSupply(), supplyBefore);
        assertEq(redemption.availableUSDC(), FUNDING);
        assertEq(redemption.totalShares(), 0);
    }

    /// @dev A revert from the external USDR burn dependency must roll back the position and
    ///      payout together. The live proxy exposes no pause entrypoint and its packed proxy
    ///      storage is intentionally not mutated here; the mock unit suite exercises the actual
    ///      `whenNotPaused` branch.
    function test_fork_redeem_rollsBackWhenUSDRBurnReverts() public {
        address receiver = makeAddr("pauseReceiver");
        uint256 redeemAmount = 1_000 * ONE_USDR;

        assertFalse(usdr.paused(), "fixture: USDR should start unpaused");
        bytes memory burnCall = abi.encodeCall(IUSDRToken.burn, (HOLDER, redeemAmount));
        bytes memory burnRevert = abi.encodeWithSignature("Error(string)", "Pausable: paused");
        vm.mockCallRevert(USDR, burnCall, burnRevert);

        uint256 supplyBefore = usdr.totalSupply();
        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), redeemAmount);
        vm.expectRevert(burnRevert);
        redemption.redeem(redeemAmount, receiver);
        vm.stopPrank();
        vm.clearMockedCalls();

        // The failed burn rolls back everything: nothing paid, nothing registered.
        assertEq(usdr.totalSupply(), supplyBefore);
        assertEq(usdc.balanceOf(receiver), 0);
        assertEq(redemption.availableUSDC(), FUNDING);
        assertEq(redemption.totalShares(), 0);
    }

    function test_fork_fund_sweep_lifecycle() public {
        // The sweep is locked while under-funded, and for 180 days after full funding; it
        // then takes everything and closes the contract.
        address treasury = makeAddr("treasury");
        uint256 redeemAmount = 10_000 * ONE_USDR;
        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), redeemAmount);
        redemption.redeem(redeemAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, type(uint256).max));
        redemption.sweep(treasury);

        _fund(redemption.remainingFunding()); // to the penny
        assertTrue(redemption.isFullyFunded());
        uint256 unlock = block.timestamp + 180 days;
        assertEq(redemption.sweepUnlockTime(), unlock);

        vm.warp(unlock - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, unlock));
        redemption.sweep(treasury);

        uint256 balance = redemption.availableUSDC();
        assertGt(redemption.claimableUSDC(HOLDER), 0, "fixture: an unclaimed remainder exists");
        vm.warp(unlock);
        vm.prank(owner);
        redemption.sweep(treasury);

        assertEq(usdc.balanceOf(treasury), balance);
        assertEq(redemption.availableUSDC(), 0);
        assertTrue(redemption.closed());
        vm.prank(HOLDER);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        redemption.claim();
    }
}

contract USDRRedemptionForkTest_NativeUSDC is USDRRedemptionForkTestBase {
    function _usdcToken() internal pure override returns (address) {
        return NATIVE_USDC;
    }

    function test_fork_redeem_revertsWhenReceiverBlacklisted() public {
        _assertRedeemRevertsWhenReceiverBlacklisted();
    }
}

contract USDRRedemptionForkTest_USDCe is USDRRedemptionForkTestBase {
    function _usdcToken() internal pure override returns (address) {
        return BRIDGED_USDCE;
    }
}
