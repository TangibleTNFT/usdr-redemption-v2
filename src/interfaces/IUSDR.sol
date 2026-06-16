// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUSDR
/// @notice Minimal interface of the Polygon USDR token (0x40379a439D4F6795B6fc9aa5687dB461677A2dBa)
///         as needed by the redemption contract.
/// @dev USDR's `burn(account, amount)` is permissionless and allowance-based: when
///      `msg.sender != account` it spends the caller's ERC-20 allowance from `account`.
///      It is NOT gated by any burner role, so the redemption contract needs no role grant
///      on the USDR token. Note `burn` is `whenNotPaused`: if Tangible pauses USDR,
///      redemptions revert until it is unpaused (external dependency).
interface IUSDR {
    /// @notice Burns `amount` USDR (9-decimal units) from `account`, spending the caller's
    ///         allowance when the caller is not `account` itself.
    function burn(address account, uint256 amount) external;
}
