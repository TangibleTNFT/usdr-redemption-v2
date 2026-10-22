// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestUSDR, TestUSDC} from "./TestTokens.sol";

interface IWrappedUSDR {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IChildWUSDR {
    function mint(address account, uint256 amount) external;
}

/// @notice Shared drip logic: a little native gas, at most once per COOLDOWN per address.
abstract contract GasDrip {
    uint256 public constant COOLDOWN = 12 hours;
    address public immutable owner;
    uint256 public immutable gasDrip;
    mapping(address => uint256) public lastDrip;

    event Dripped(address indexed to, uint256 gas);

    error TooSoon(uint256 nextDripAt);

    constructor(uint256 gasDrip_) {
        owner = msg.sender;
        gasDrip = gasDrip_;
    }

    receive() external payable {}

    function _dripGas(address to) internal returns (uint256 sent) {
        uint256 next = lastDrip[to] + COOLDOWN;
        if (lastDrip[to] != 0 && block.timestamp < next) revert TooSoon(next);
        lastDrip[to] = block.timestamp;
        sent = address(this).balance < gasDrip ? address(this).balance : gasDrip;
        if (sent != 0) {
            (bool ok,) = to.call{value: sent}("");
            require(ok, "gas transfer failed");
        }
        emit Dripped(to, sent);
    }

    /// @notice Owner: take back leftover gas.
    function withdraw() external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }
}

/// @notice Hub chain (stands in for Polygon): gas, test USDR, and wUSDR in one call.
contract HubFaucet is GasDrip {
    uint256 public constant USDR_DRIP = 100_000e9;
    uint256 public constant WUSDR_DRIP_IN_USDR = 10_000e9;

    TestUSDR public immutable usdr;
    TestUSDC public immutable usdc;
    IWrappedUSDR public immutable wusdr;

    constructor(TestUSDR usdr_, TestUSDC usdc_, IWrappedUSDR wusdr_, uint256 gasDrip_) GasDrip(gasDrip_) {
        usdr = usdr_;
        usdc = usdc_;
        wusdr = wusdr_;
        usdr_.approve(address(wusdr_), type(uint256).max);
    }

    /// @notice Sends you some ETH for gas, 100,000 test USDR and ~9,267 wUSDR (10,000 USDR wrapped).
    ///         Once per 12 hours. For other amounts call mint() on the token contracts directly.
    function drip() external {
        _dripGas(msg.sender);
        usdr.mint(msg.sender, USDR_DRIP);
        usdr.mint(address(this), WUSDR_DRIP_IN_USDR);
        wusdr.deposit(WUSDR_DRIP_IN_USDR, msg.sender);
    }
}

/// @notice Side chain (stands in for Base/Optimism/...): gas and side-chain wUSDR.
///         This faucet is the ChildWUSDR migrator; every wUSDR it mints is backed by the
///         wUSDR pre-locked in the hub's WrappedUSDR, so bridging home always works.
contract SideFaucet is GasDrip {
    uint256 public constant WUSDR_DRIP = 10_000e9;
    uint256 public constant MAX_MINT = 1_000_000e9;

    IChildWUSDR public immutable wusdr;

    constructor(IChildWUSDR wusdr_, uint256 gasDrip_) GasDrip(gasDrip_) {
        wusdr = wusdr_;
    }

    /// @notice Sends you some ETH for gas and 10,000 wUSDR. Once per 12 hours.
    function drip() external {
        _dripGas(msg.sender);
        wusdr.mint(msg.sender, WUSDR_DRIP);
    }

    /// @notice Mint any amount of side-chain wUSDR (raw units, 9 decimals; max 1,000,000 wUSDR per call).
    function mint(address to, uint256 amount) external {
        require(amount <= MAX_MINT, "max 1,000,000 wUSDR per call");
        wusdr.mint(to, amount);
    }
}
