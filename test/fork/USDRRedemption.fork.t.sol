// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {USDRRedemption} from "../../src/USDRRedemption.sol";

interface IUSDRToken is IERC20 {
    function burn(address account, uint256 amount) external;
    function paused() external view returns (bool);
}

/// @notice Polygon fork integration tests: redeem REAL USDR end to end against the live
///         token (allowance-based burn, rebasing balances), parameterized over the USDC
///         flavour via {_usdcToken}. Run with POLYGON_RPC_URL set, or fall back to a
///         public endpoint (https://chainlist.org/rpcs.json).
abstract contract USDRRedemptionForkTestBase is Test {
    // Live Polygon addresses (spec §10).
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
    uint256 internal constant FUNDING = 1_000_000e6; // 1M USDC

    USDRRedemption internal redemption;
    IUSDRToken internal usdr = IUSDRToken(USDR);
    IERC20 internal usdc;

    address internal owner = makeAddr("safeOwner");

    /// @dev Concrete suites pick native USDC or bridged USDC.e.
    function _usdcToken() internal pure virtual returns (address);

    function setUp() public {
        vm.createSelectFork(vm.envOr("POLYGON_RPC_URL", FALLBACK_RPC), FORK_BLOCK);
        usdc = IERC20(_usdcToken());

        redemption = new USDRRedemption(USDR, _usdcToken(), RATE, owner);

        // Tangible funds the contract: give the owner USDC and fund() through the
        // explicit entrypoint so the sweep clock is stamped, as in production.
        deal(_usdcToken(), owner, FUNDING);
        vm.startPrank(owner);
        usdc.approve(address(redemption), FUNDING);
        redemption.fund(FUNDING);
        vm.stopPrank();

        assertFalse(usdr.paused(), "USDR token is paused on this fork");
    }

    function test_fork_redeem_realUSDR_endToEnd() public {
        uint256 redeemAmount = 10_000 * ONE_USDR;
        uint256 holderUsdrBefore = usdr.balanceOf(HOLDER);
        uint256 holderUsdcBefore = usdc.balanceOf(HOLDER);
        uint256 supplyBefore = usdr.totalSupply();
        assertGe(holderUsdrBefore, redeemAmount, "holder no longer has enough USDR");

        uint256 expectedUsdc = (redeemAmount * RATE) / ONE_USDR; // 5,417 USDC

        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), redeemAmount);
        uint256 paid = redemption.redeem(redeemAmount);
        vm.stopPrank();

        assertEq(paid, expectedUsdc);
        assertEq(usdc.balanceOf(HOLDER) - holderUsdcBefore, expectedUsdc);
        assertEq(usdc.balanceOf(address(redemption)), FUNDING - expectedUsdc);
        // USDR is rebasing (ray-math index), so balance/supply deltas can carry a
        // ~1-unit (1e-9 USDR) rounding wobble.
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

        assertEq(usdc.balanceOf(receiver), (redeemAmount * RATE) / ONE_USDR);
    }

    function test_fork_redeem_revertsWithoutApproval() public {
        vm.prank(HOLDER);
        vm.expectRevert(); // real USDR: allowance spend underflows/reverts
        redemption.redeem(1_000 * ONE_USDR);
    }

    function test_fork_redeem_revertsOnZeroPayout() public {
        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), 1);
        vm.expectRevert(USDRRedemption.ZeroPayout.selector);
        redemption.redeem(1); // 1e-9 USDR rounds to zero USDC
        vm.stopPrank();
    }

    function test_fork_redeem_revertsBeyondAvailableUSDC() public {
        // The holder's full position (~4.1M USDR -> ~2.2M USDC) exceeds the 1M funding.
        uint256 holderBalance = usdr.balanceOf(HOLDER);
        uint256 required = (holderBalance * RATE) / ONE_USDR;
        assertGt(required, FUNDING, "fixture: holder position should exceed funding");

        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), holderBalance);
        vm.expectRevert(
            abi.encodeWithSelector(USDRRedemption.InsufficientUSDC.selector, required, FUNDING)
        );
        redemption.redeem(holderBalance);
        vm.stopPrank();
    }

    function test_fork_maxRedeemable_fitsAndRedeems() public {
        uint256 maxUsdr = redemption.maxRedeemableUSDR();
        assertLe(redemption.previewRedeem(maxUsdr), redemption.availableUSDC());
        assertGe(usdr.balanceOf(HOLDER), maxUsdr, "fixture: holder cannot cover max");

        vm.startPrank(HOLDER);
        usdr.approve(address(redemption), maxUsdr);
        redemption.redeem(maxUsdr);
        vm.stopPrank();

        // Pot is drained below the smallest payable unit.
        assertLt(redemption.availableUSDC(), RATE / 1e3 + 1);
    }

    function test_fork_fund_sweep_lifecycle() public {
        // Sweep is locked while funding keeps coming, opens 180 days after the last one.
        address treasury = makeAddr("treasury");

        vm.warp(block.timestamp + 100 days);
        deal(_usdcToken(), owner, 50_000e6);
        vm.startPrank(owner);
        usdc.approve(address(redemption), 50_000e6);
        redemption.fund(50_000e6); // resets the clock at day 100

        uint256 unlock = redemption.sweepUnlockTime();
        vm.warp(unlock - 1);
        vm.expectRevert(abi.encodeWithSelector(USDRRedemption.SweepLocked.selector, unlock));
        redemption.sweep(treasury);

        vm.warp(unlock);
        redemption.sweep(treasury);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury), FUNDING + 50_000e6);
        assertEq(redemption.availableUSDC(), 0);
    }
}

contract USDRRedemptionForkTest_NativeUSDC is USDRRedemptionForkTestBase {
    function _usdcToken() internal pure override returns (address) {
        return NATIVE_USDC;
    }
}

contract USDRRedemptionForkTest_USDCe is USDRRedemptionForkTestBase {
    function _usdcToken() internal pure override returns (address) {
        return BRIDGED_USDCE;
    }
}
