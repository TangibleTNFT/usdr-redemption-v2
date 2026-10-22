// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {TestnetConfig} from "./TestnetConfig.sol";
import {TestUSDR, TestUSDC} from "../../testnet/TestTokens.sol";
import {TestnetRedemptionFactory} from "../../testnet/TestnetRedemptionFactory.sol";
import {TestnetUSDRRedemption} from "../../testnet/TestnetUSDRRedemption.sol";
import {HubFaucet, IWrappedUSDR} from "../../testnet/Faucets.sol";

interface IWrappedUSDRAdmin {
    function initialize(address owner, address usdr, address lzEndpoint) external;
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

/// @notice Hub side of the testnet replica (Arbitrum Sepolia): test USDR/USDC, the live
///         WrappedUSDR bytecode with a pre-filled bridge lock, the redemption factory with a
///         mainnet-like default instance funded to 50%, and the faucet.
contract DeployHub is TestnetConfig {
    /// @dev wUSDR locked in WrappedUSDR itself, backing everything the side-chain faucet mints.
    uint256 internal constant LOCK_SEED_USDR = 1_000_000_000e9;
    uint256 internal constant GAS_DRIP = 0.01 ether;

    function run() external {
        require(block.chainid == HUB_CHAIN_ID, "hub = Arbitrum Sepolia");
        uint256 faucetGas = vm.envOr("FAUCET_GAS", uint256(1 ether));

        vm.startBroadcast();
        address me = msg.sender;
        TestUSDR usdr = new TestUSDR();
        TestUSDC usdc = new TestUSDC();

        address wusdr = _deployRaw("testnet/artifacts/WrappedUSDR.json");
        IWrappedUSDRAdmin(wusdr).initialize(me, address(usdr), HUB_LZ_ENDPOINT);
        usdr.mint(me, LOCK_SEED_USDR);
        usdr.approve(wusdr, LOCK_SEED_USDR);
        IWrappedUSDRAdmin(wusdr).deposit(LOCK_SEED_USDR, wusdr);

        TestnetRedemptionFactory factory = new TestnetRedemptionFactory(address(usdr), usdc);
        address dflt = factory.createMainnetLike(180 days);
        factory.fundToPercent(TestnetUSDRRedemption(dflt), 50);

        HubFaucet faucet = new HubFaucet(usdr, usdc, IWrappedUSDR(wusdr), GAS_DRIP);
        (bool ok,) = address(faucet).call{value: faucetGas}("");
        require(ok, "faucet funding failed");
        vm.stopBroadcast();

        string memory k = "hub";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "lzChainId", HUB_LZ_ID);
        vm.serializeAddress(k, "lzEndpoint", HUB_LZ_ENDPOINT);
        vm.serializeAddress(k, "USDR", address(usdr));
        vm.serializeAddress(k, "USDC", address(usdc));
        vm.serializeAddress(k, "wUSDR", wusdr);
        vm.serializeAddress(k, "redemptionFactory", address(factory));
        vm.serializeAddress(k, "defaultRedemption", dflt);
        string memory out = vm.serializeAddress(k, "faucet", address(faucet));
        vm.writeJson(out, HUB_JSON);
        console.log("hub written to", HUB_JSON);
    }
}
