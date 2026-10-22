// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestnetUSDRRedemption} from "./TestnetUSDRRedemption.sol";
import {TestUSDC} from "./TestTokens.sol";

/// @notice Lets testers create their own redemption contracts and drive the owner side
///         (funding, rate, sweep) from the block explorer, without holding test USDC.
///         The factory owns every instance it creates; only an instance's creator may
///         manage it, so testers cannot disturb each other's runs.
contract TestnetRedemptionFactory {
    uint256 public constant USDR_UNIT = 1e9;
    /// @notice Mainnet deployment values (Polygon 0x58FC3e034AC4721DC977d166Eea89e6d069aE906).
    uint256 public constant MAINNET_TOTAL_SUPPLY_USDR = 35_909_552;
    uint256 public constant MAINNET_RATE = 535_516;

    address public immutable usdr;
    TestUSDC public immutable usdc;

    address[] public instances;
    mapping(address instance => address creator) public creatorOf;

    event InstanceCreated(
        address indexed instance, address indexed creator, uint256 totalSupplyUSDR, uint256 rate, uint256 sweepDelay
    );

    error NotCreator(address instance, address creator);
    error NothingToFund();
    error BadPercent();

    constructor(address usdr_, TestUSDC usdc_) {
        usdr = usdr_;
        usdc = usdc_;
    }

    modifier onlyCreator(TestnetUSDRRedemption r) {
        address c = creatorOf[address(r)];
        if (c != msg.sender) revert NotCreator(address(r), c);
        _;
    }

    // ------------------------------------------------------------------ create

    /// @notice New redemption contract with custom parameters; you manage it through this factory.
    /// @param totalSupplyUSDR Redeemable USDR supply in WHOLE tokens (e.g. 1000 = 1,000 USDR).
    /// @param rate            USDC raw units per whole USDR (535516 = $0.535516; max 1000000).
    /// @param sweepDelay      Seconds from full funding until the sweep is allowed (mainnet: 15552000 = 180 days).
    function create(uint256 totalSupplyUSDR, uint256 rate, uint256 sweepDelay) public returns (address instance) {
        instance = address(
            new TestnetUSDRRedemption(usdr, address(usdc), rate, totalSupplyUSDR * USDR_UNIT, address(this), sweepDelay)
        );
        instances.push(instance);
        creatorOf[instance] = msg.sender;
        emit InstanceCreated(instance, msg.sender, totalSupplyUSDR, rate, sweepDelay);
    }

    /// @notice New redemption contract with the mainnet supply and rate.
    /// @param sweepDelay Seconds from full funding until the sweep is allowed (e.g. 600 = 10 minutes).
    function createMainnetLike(uint256 sweepDelay) external returns (address) {
        return create(MAINNET_TOTAL_SUPPLY_USDR, MAINNET_RATE, sweepDelay);
    }

    function instanceCount() external view returns (uint256) {
        return instances.length;
    }

    function allInstances() external view returns (address[] memory) {
        return instances;
    }

    function instancesOf(address creator) external view returns (address[] memory out) {
        uint256 n;
        for (uint256 i; i < instances.length; ++i) {
            if (creatorOf[instances[i]] == creator) ++n;
        }
        out = new address[](n);
        n = 0;
        for (uint256 i; i < instances.length; ++i) {
            if (creatorOf[instances[i]] == creator) out[n++] = instances[i];
        }
    }

    // ------------------------------------------------------------------ owner actions

    /// @notice Fund the instance with freshly minted test USDC. `usdcAmount` in raw units
    ///         (6 decimals: 1 USDC = 1000000). Must not exceed remainingFunding().
    function fund(TestnetUSDRRedemption r, uint256 usdcAmount) public onlyCreator(r) {
        usdc.mint(address(this), usdcAmount);
        usdc.approve(address(r), usdcAmount);
        r.fund(usdcAmount);
    }

    /// @notice Fund the instance up to `percent` of expectedFunding() (100 = fully funded).
    function fundToPercent(TestnetUSDRRedemption r, uint256 percent) external onlyCreator(r) {
        if (percent == 0 || percent > 100) revert BadPercent();
        uint256 target = percent == 100 ? r.expectedFunding() : r.expectedFunding() * percent / 100;
        uint256 funded = r.totalFunded();
        if (target <= funded) revert NothingToFund();
        fund(r, target - funded);
    }

    /// @notice Simulates someone sending USDC straight to the contract (not counted as funding).
    function sendUSDCDirectly(TestnetUSDRRedemption r, uint256 usdcAmount) external onlyCreator(r) {
        usdc.mint(address(r), usdcAmount);
    }

    /// @notice Owner: count USDC already sitting in the contract as funding.
    function fundFromBalance(TestnetUSDRRedemption r, uint256 usdcAmount) external onlyCreator(r) {
        r.fundFromBalance(usdcAmount);
    }

    /// @notice Owner: raise the rate (USDC raw units per whole USDR; only up, max 1000000).
    function setRate(TestnetUSDRRedemption r, uint256 newRate) external onlyCreator(r) {
        r.setRate(newRate);
    }

    /// @notice Owner: sweep all USDC to `to` and close the contract (only after sweepUnlockTime()).
    function sweep(TestnetUSDRRedemption r, address to) external onlyCreator(r) {
        r.sweep(to);
    }

    /// @notice Owner: recover a non-USDC token sent to the contract.
    function rescueERC20(TestnetUSDRRedemption r, address token, address to) external onlyCreator(r) {
        r.rescueERC20(token, to);
    }
}
