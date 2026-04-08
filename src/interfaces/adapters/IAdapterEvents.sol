// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAdapterEvents {
    /// @notice Standardized pause state update event across all adapters.
    event AdapterPaused(address indexed adapter, bool paused);

    /// @notice Standardized invest event emitted after a successful deposit.
    event AdapterDeposit(
        address indexed adapter, address indexed caller, uint256 amount, address indexed receiver, uint256 sharesOrPos
    );

    /// @notice Standardized sync redeem event emitted after a successful withdrawSync.
    event AdapterWithdrawSync(
        address indexed adapter, address indexed caller, uint256 amount, address indexed receiver, uint256 actualAmount
    );

    /// @notice Standardized async redeem request event.
    event AdapterRedeemRequested(
        address indexed adapter, address indexed caller, uint256 amount, address indexed receiver
    );
}
