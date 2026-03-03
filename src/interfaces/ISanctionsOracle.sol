// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISanctionsOracle
 * @notice On-chain AML / sanctions blacklist registry interface.
 * @dev    Consumed by MantleYieldVault to gate deposits, redemptions, and transfers.
 */
interface ISanctionsOracle {
    // ─────────────────────────────────────────────────────────────
    //                          EVENTS
    // ─────────────────────────────────────────────────────────────

    /// @notice Fired for every individual address whose sanction status actually changes.
    /// @param account     The affected address.
    /// @param sanctioned  `true` = newly sanctioned, `false` = lifted.
    event SanctionStatusUpdated(address indexed account, bool sanctioned);

    /// @notice Fired once per `updateSanctionStatusBatch` call (including no-ops).
    /// @param batchId     Monotonically increasing counter for reliable off-chain correlation.
    /// @param processed   Total addresses submitted in the call.
    /// @param changed     How many actually flipped state (≤ processed).
    /// @param sanctioned  The target status applied to the batch.
    event BatchSanctionUpdated(uint256 indexed batchId, uint256 processed, uint256 changed, bool sanctioned);

    // ─────────────────────────────────────────────────────────────
    //                          ERRORS
    // ─────────────────────────────────────────────────────────────

    /// @dev Batch array is empty.
    error Oracle__EmptyArray();

    /// @dev Batch array exceeds `MAX_BATCH_SIZE`.
    error Oracle__BatchTooLarge(uint256 provided, uint256 maximum);

    /// @dev Zero address passed as an account.
    error Oracle__ZeroAddress();

    // ─────────────────────────────────────────────────────────────
    //                        READ FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    /// @notice Primary check consumed by Vault (matches the name in IMantleYieldVault).
    /// @param account Address to query.
    /// @return `true` if the address is currently blacklisted / sanctioned.
    function isBlacklisted(address account) external view returns (bool);

    /// @notice Alias — same semantics as `isBlacklisted`.
    function isSanctioned(address account) external view returns (bool);

    /// @notice Number of addresses that are currently sanctioned.
    function totalSanctionedCount() external view returns (uint256);

    /// @notice Block timestamp of the last state-mutating update (used for liveness monitoring).
    function lastUpdateTimestamp() external view returns (uint256);

    /// @notice Monotonically increasing counter incremented on every batch call.
    function batchNonce() external view returns (uint256);

    /// @notice Implementation-defined upper bound on batch size.
    function MAX_BATCH_SIZE() external view returns (uint256);

    // ─────────────────────────────────────────────────────────────
    //                       WRITE FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    /// @notice Update a single address — optimal for emergency bans.
    /// @param account    The address to sanction / unsanction.
    /// @param sanctioned `true` to ban, `false` to lift.
    function updateSanctionStatus(address account, bool sanctioned) external;

    /// @notice Batch update — the primary path used by the off-chain Compliance Service.
    /// @param accounts   Array of addresses to update (length ≤ MAX_BATCH_SIZE).
    /// @param sanctioned `true` to ban all, `false` to lift all.
    function updateSanctionStatusBatch(address[] calldata accounts, bool sanctioned) external;
}
