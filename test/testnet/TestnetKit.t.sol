// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IUSDRRedemption} from "../../src/interfaces/IUSDRRedemption.sol";
import {TestUSDR, TestUSDC} from "../../testnet/TestTokens.sol";
import {TestnetRedemptionFactory} from "../../testnet/TestnetRedemptionFactory.sol";
import {TestnetUSDRRedemption} from "../../testnet/TestnetUSDRRedemption.sol";
import {HubFaucet, SideFaucet, GasDrip, IWrappedUSDR, IChildWUSDR} from "../../testnet/Faucets.sol";

interface IWUSDR {
    function initialize(address owner, address usdr, address lzEndpoint) external;
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IChild {
    function initialize(address owner, address lzEndpoint) external;
    function setMigrator(address) external;
    function balanceOf(address) external view returns (uint256);
}

/// @notice Exercises the testnet kit locally, with the live WrappedUSDR / ChildWUSDR bytecode.
contract TestnetKitTest is Test {
    TestUSDR usdr;
    TestUSDC usdc;
    TestnetRedemptionFactory factory;
    address milica = makeAddr("milica");
    address jiggy = makeAddr("jiggy");

    function setUp() public {
        usdr = new TestUSDR();
        usdc = new TestUSDC();
        factory = new TestnetRedemptionFactory(address(usdr), usdc);
    }

    function _raw(string memory artifact) internal returns (address a) {
        bytes memory code = vm.parseJsonBytes(vm.readFile(artifact), ".bytecode");
        assembly {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0));
    }

    function test_FullRedemptionLifecycle() public {
        vm.prank(milica);
        TestnetUSDRRedemption r = TestnetUSDRRedemption(factory.createMainnetLike(600));
        assertEq(r.SWEEP_DELAY(), 600);
        assertEq(r.totalUSDRSupply(), 35_909_552e9);
        assertEq(r.rate(), 535_516);
        assertEq(factory.instancesOf(milica).length, 1);

        // Unfunded: redeem burns, pays 0, registers shares.
        usdr.mint(jiggy, 1000e9);
        vm.startPrank(jiggy);
        usdr.approve(address(r), type(uint256).max);
        assertEq(r.redeem(400e9), 0);
        vm.expectRevert(IUSDRRedemption.NothingToClaim.selector);
        r.claim();
        vm.stopPrank();

        // Only the creator can manage it.
        vm.prank(jiggy);
        vm.expectRevert(abi.encodeWithSelector(TestnetRedemptionFactory.NotCreator.selector, address(r), milica));
        factory.fundToPercent(r, 30);

        // 30% funded.
        vm.prank(milica);
        factory.fundToPercent(r, 30);
        assertApproxEqAbs(r.effectiveRate(), 160_654, 1);
        uint256 owed = r.claimableUSDC(jiggy);
        assertApproxEqAbs(owed, 400 * 160_654, 400);
        vm.prank(jiggy);
        assertEq(r.claim(), owed);

        // Fully funded, then the rate goes up and the countdown resets.
        vm.prank(milica);
        factory.fundToPercent(r, 100);
        assertTrue(r.isFullyFunded());
        assertEq(r.sweepUnlockTime(), block.timestamp + 600);
        vm.prank(milica);
        factory.setRate(r, 600_000);
        assertFalse(r.isFullyFunded());
        vm.prank(milica);
        factory.fundToPercent(r, 100);
        (, uint128 paidBefore) = r.positions(jiggy);
        vm.prank(jiggy);
        assertApproxEqAbs(r.redeem(600e9), 1000 * 600_000 - uint256(paidBefore), 1);

        // Sweep: locked, then allowed after the delay; the contract closes.
        vm.prank(milica);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.SweepLocked.selector, block.timestamp + 600));
        factory.sweep(r, milica);
        skip(600);
        vm.prank(milica);
        factory.sweep(r, milica);
        assertTrue(r.closed());
        vm.prank(jiggy);
        vm.expectRevert(IUSDRRedemption.ContractClosed.selector);
        r.redeem(1);
    }

    function test_TinySupplyHitsShareCap() public {
        vm.prank(milica);
        TestnetUSDRRedemption r = TestnetUSDRRedemption(factory.create(1000, 535_516, 600));
        usdr.mint(jiggy, 2000e9);
        vm.startPrank(jiggy);
        usdr.approve(address(r), type(uint256).max);
        r.redeem(1000e9);
        assertEq(r.maxRedeemableUSDR(), 0);
        vm.expectRevert(abi.encodeWithSelector(IUSDRRedemption.ShareCapExceeded.selector, 1e9, 0));
        r.redeem(1e9);
        vm.stopPrank();
    }

    function test_DirectTransferThenFundFromBalance() public {
        vm.startPrank(milica);
        TestnetUSDRRedemption r = TestnetUSDRRedemption(factory.create(1000, 535_516, 600));
        factory.sendUSDCDirectly(r, 100e6);
        assertEq(r.totalFunded(), 0);
        factory.fundFromBalance(r, 100e6);
        assertEq(r.totalFunded(), 100e6);
        vm.stopPrank();
    }

    function test_HubFaucetAndUnwrap() public {
        IWUSDR w = IWUSDR(_raw("testnet/artifacts/WrappedUSDR.json"));
        w.initialize(address(this), address(usdr), address(0xBEEF));
        HubFaucet f = new HubFaucet(usdr, usdc, IWrappedUSDR(address(w)), 0.01 ether);
        vm.deal(address(f), 1 ether);

        vm.prank(milica);
        f.drip();
        assertEq(milica.balance, 0.01 ether);
        assertEq(usdr.balanceOf(milica), 100_000e9);
        uint256 shares = w.balanceOf(milica);
        assertApproxEqAbs(shares, 9_267_173_073_880, 1); // 10,000 USDR / 1.0790777 per wUSDR

        vm.prank(milica);
        vm.expectRevert(abi.encodeWithSelector(GasDrip.TooSoon.selector, block.timestamp + 12 hours));
        f.drip();

        // Unwrap all wUSDR back to USDR (the hub step of "Bring wUSDR home").
        uint256 all = w.maxRedeem(milica);
        vm.prank(milica);
        uint256 got = w.redeem(all, milica, milica);
        assertApproxEqAbs(got, 10_000e9, 1);

        skip(12 hours);
        vm.prank(milica);
        f.drip();
    }

    function test_SideFaucet() public {
        IChild c = IChild(_raw("testnet/artifacts/ChildWUSDR.json"));
        c.initialize(address(this), address(0xBEEF));
        SideFaucet f = new SideFaucet(IChildWUSDR(address(c)), 0.03 ether);
        c.setMigrator(address(f));

        vm.prank(jiggy);
        f.drip();
        assertEq(c.balanceOf(jiggy), 10_000e9);
        assertEq(jiggy.balance, 0); // faucet holds no gas: tokens still delivered
        f.mint(jiggy, 1_000_000e9);
        vm.expectRevert("max 1,000,000 wUSDR per call");
        f.mint(jiggy, 1_000_000e9 + 1);
    }
}
