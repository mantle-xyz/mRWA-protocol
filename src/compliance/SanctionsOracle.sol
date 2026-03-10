// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../interfaces/compliance/ISanctionsOracle.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title  SanctionsOracle
 * @author Mantle RWA Team
 * @notice On-chain AML blacklist registry that gates MantleYieldVault operations.
 *         Deployed behind a **BeaconProxy** for unified upgradability across instances.
 */
contract SanctionsOracle is ISanctionsOracle, AccessControlUpgradeable {
    // ─────────────────────────────────────────────────────────────
    //                          CONSTANTS
    // ─────────────────────────────────────────────────────────────

    /// @notice Role granted to the off-chain Compliance Bot.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @notice Hard ceiling on addresses per batch call to bound gas usage.
    /// @dev    200 addresses ≈ 1.4 M gas worst-case (cold SSTORE); fits comfortably in a single block.
    uint256 public constant MAX_BATCH_SIZE = 200;

    // ─────────────────────────────────────────────────────────────
    //                   ERC-7201 NAMESPACED STORAGE
    // ─────────────────────────────────────────────────────────────

    /// @custom:storage-location erc7201:mrwa.storage.SanctionsOracle
    struct SanctionsOracleStorage {
        /// @dev Core mapping: `true` ⇒ address is currently sanctioned.
        mapping(address account => bool sanctioned) _sanctioned;
        /// @dev Running count of distinct sanctioned addresses.
        uint256 _totalSanctionedCount;
        /// @dev Block timestamp of the most recent state-mutating update.
        uint256 _lastUpdateTimestamp;
        /// @dev Monotonically increasing counter; incremented on every batch call.
        uint256 _batchNonce;
    }

    // keccak256(abi.encode(uint256(keccak256("mrwa.storage.SanctionsOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SANCTIONS_ORACLE_STORAGE =
        0xeaa83cc192d853a8f8b5bdc027bbf14a5aadb833634a75893f2171049ea64b00;

    function _getStorage() private pure returns (SanctionsOracleStorage storage $) {
        bytes32 slot = SANCTIONS_ORACLE_STORAGE;
        assembly {
            $.slot := slot
        }
    }

    // ─────────────────────────────────────────────────────────────
    //              CONSTRUCTOR (locks implementation)
    // ─────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─────────────────────────────────────────────────────────────
    //                         INITIALIZER
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Proxy initialization — replaces the constructor.
     * @dev    Called exactly once per proxy via `BeaconProxy(beacon, abi.encodeCall(...))`.
     * @param admin_         Address receiving `DEFAULT_ADMIN_ROLE` (typically a multisig / timelock).
     * @param complianceBot_ Address receiving `COMPLIANCE_ROLE` (the off-chain Sanctions Service hot-wallet).
     */
    function initialize(address admin_, address complianceBot_) external initializer {
        if (admin_ == address(0)) revert Oracle__ZeroAddress();
        if (complianceBot_ == address(0)) revert Oracle__ZeroAddress();

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(COMPLIANCE_ROLE, complianceBot_);

        _getStorage()._lastUpdateTimestamp = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────
    //                       READ FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc ISanctionsOracle
    function isSanctioned(address account) external view override returns (bool) {
        return _getStorage()._sanctioned[account];
    }

    /// @inheritdoc ISanctionsOracle
    function totalSanctionedCount() external view override returns (uint256) {
        return _getStorage()._totalSanctionedCount;
    }

    /// @inheritdoc ISanctionsOracle
    function lastUpdateTimestamp() external view override returns (uint256) {
        return _getStorage()._lastUpdateTimestamp;
    }

    /// @inheritdoc ISanctionsOracle
    function batchNonce() external view override returns (uint256) {
        return _getStorage()._batchNonce;
    }

    // ─────────────────────────────────────────────────────────────
    //                          ERC-165
    // ─────────────────────────────────────────────────────────────

    /// @dev Declare support for ISanctionsOracle so Vault can verify the oracle at setup time.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(ISanctionsOracle).interfaceId || super.supportsInterface(interfaceId);
    }

    // ─────────────────────────────────────────────────────────────
    //                       WRITE FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc ISanctionsOracle
    function updateSanctionStatus(address account, bool sanctioned) external onlyRole(COMPLIANCE_ROLE) {
        if (account == address(0)) revert Oracle__ZeroAddress();

        SanctionsOracleStorage storage s = _getStorage();
        uint256 changed;

        if (s._sanctioned[account] != sanctioned) {
            s._sanctioned[account] = sanctioned;

            if (sanctioned) {
                unchecked {
                    ++s._totalSanctionedCount;
                }
            } else {
                // Safe: count ≥ 1 because `_sanctioned[account]` was `true`.
                unchecked {
                    --s._totalSanctionedCount;
                }
            }

            s._lastUpdateTimestamp = block.timestamp;
            changed = 1;

            emit SanctionStatusUpdated(account, sanctioned);
        }

        // Batch event with processed=1 for consistent off-chain indexing.
        uint256 nonce;
        unchecked {
            nonce = s._batchNonce++;
        }
        emit BatchSanctionUpdated(nonce, 1, changed, sanctioned);
    }

    /// @inheritdoc ISanctionsOracle
    function updateSanctionStatusBatch(address[] calldata accounts, bool sanctioned)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        uint256 len = accounts.length;
        if (len == 0) revert Oracle__EmptyArray();
        if (len > MAX_BATCH_SIZE) revert Oracle__BatchTooLarge(len, MAX_BATCH_SIZE);

        SanctionsOracleStorage storage s = _getStorage();

        // Cache in memory to avoid repeated SLOAD / SSTORE inside the loop.
        uint256 cachedCount = s._totalSanctionedCount;
        uint256 effectiveChanges;

        for (uint256 i; i < len;) {
            address account = accounts[i];
            if (account == address(0)) revert Oracle__ZeroAddress();

            if (s._sanctioned[account] != sanctioned) {
                s._sanctioned[account] = sanctioned;

                if (sanctioned) {
                    unchecked {
                        ++cachedCount;
                    }
                } else {
                    unchecked {
                        --cachedCount;
                    }
                }

                emit SanctionStatusUpdated(account, sanctioned);

                unchecked {
                    ++effectiveChanges;
                }
            }

            unchecked {
                ++i;
            }
        }

        // Single SSTORE for count (only if something changed).
        if (effectiveChanges > 0) {
            s._totalSanctionedCount = cachedCount;
            s._lastUpdateTimestamp = block.timestamp;
        }

        // Always emit the batch event so off-chain can track every invocation.
        uint256 nonce;
        unchecked {
            nonce = s._batchNonce++;
        }
        emit BatchSanctionUpdated(nonce, len, effectiveChanges, sanctioned);
    }
}
