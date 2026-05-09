// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IAccessControlLike {
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IDefaultAdminRulesLike {
    function defaultAdmin() external view returns (address);
    function pendingDefaultAdmin() external view returns (address newAdmin, uint48 schedule);
    function beginDefaultAdminTransfer(address newAdmin) external;
    function acceptDefaultAdminTransfer() external;
}

interface IOwnableLike {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IBeaconFactoryLike {
    function BEACON() external view returns (IOwnableLike);
}

/// @title TransferProtocolOwnership
/// @notice Two-step admin transfer helper for protocol proxies and Beacon ownership.
///
/// Grant/transfer phase (default):
/// - Grants DEFAULT_ADMIN_ROLE to TRANSFER_NEW_ADMIN on plain AccessControl proxies.
/// - Begins default-admin transfer on AccessControlDefaultAdminRules proxies.
/// - Transfers each factory BEACON owner to TRANSFER_NEW_BEACON_OWNER.
///
/// Accept phase:
/// - Set TRANSFER_ACCEPT_DEFAULT_ADMIN=true after the default-admin delay has passed.
/// - The current sender must be TRANSFER_NEW_ADMIN because AccessControlDefaultAdminRules
///   only allows the pending admin to accept.
///
/// Renounce phase:
/// - Set TRANSFER_RENOUNCE_OLD_ADMIN=true after all default-admin transfers have been accepted.
/// - The current sender must be TRANSFER_OLD_ADMIN because AccessControl.renounceRole
///   only allows an account to renounce its own role.
///
/// Required env:
/// - TRANSFER_OLD_ADMIN
/// - TRANSFER_NEW_ADMIN
/// - TRANSFER_NEW_BEACON_OWNER
///
/// Proxy envs (TRANSFER_* wins; fallback to deployment config names when present):
/// - TRANSFER_VAULT                       fallback UPGRADE_INIT_VAULT_PROXY / EXISTING_VAULT_PROXY
/// - TRANSFER_GATEWAY                     fallback UPGRADE_INIT_GATEWAY / F_GATEWAY
/// - TRANSFER_ACCOUNTANT                  fallback UPGRADE_INIT_ACCOUNTANT / F_ACCOUNTANT
/// - TRANSFER_CONTROLLER                  fallback UPGRADE_INIT_CONTROLLER / F_CONTROLLER_ADDRESS
/// - TRANSFER_SANCTIONS_ORACLE            fallback F_SANCTIONS_ORACLE
/// - TRANSFER_ACCOUNTANT_EXECUTOR         fallback UPGRADE_INIT_ACCOUNTANT_EXECUTOR / F_ACCOUNTANT_EXECUTOR
/// - TRANSFER_OPERATOR_EXECUTOR           fallback UPGRADE_INIT_OPERATOR_EXECUTOR / F_OPERATOR_EXECUTOR
/// - TRANSFER_ADAPTER                     fallback UPGRADE_INIT_ADAPTER_PROXY / F_STRATEGY_ADAPTER_ADDRESS
///
/// Factory envs:
/// - TRANSFER_VAULT_FACTORY               fallback UPGRADE_INIT_VAULT_FACTORY / F_VAULT_FACTORY
/// - TRANSFER_GATEWAY_FACTORY             fallback F_GATEWAY_FACTORY
/// - TRANSFER_ACCOUNTANT_FACTORY          fallback F_ACCOUNTANT_FACTORY
/// - TRANSFER_CONTROLLER_FACTORY          fallback F_STRATEGY_CONTROLLER_FACTORY
/// - TRANSFER_SANCTIONS_ORACLE_FACTORY    fallback F_SANCTIONS_ORACLE_FACTORY
/// - TRANSFER_SUBRED_ADAPTER_FACTORY      fallback UPGRADE_INIT_SUBRED_ADAPTER_FACTORY
contract TransferProtocolOwnership is Script {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function run() external {
        address oldAdmin = vm.envOr("TRANSFER_OLD_ADMIN", address(0));
        address newAdmin = vm.envOr("TRANSFER_NEW_ADMIN", address(0));
        address newBeaconOwner = vm.envOr("TRANSFER_NEW_BEACON_OWNER", address(0));
        bool acceptDefaultAdmin = _envBool("TRANSFER_ACCEPT_DEFAULT_ADMIN", false);
        bool renounceOldAdmin = _envBool("TRANSFER_RENOUNCE_OLD_ADMIN", false);

        _requireNonZero(oldAdmin, "TRANSFER_OLD_ADMIN");
        _requireNonZero(newAdmin, "TRANSFER_NEW_ADMIN");
        _requireNonZero(newBeaconOwner, "TRANSFER_NEW_BEACON_OWNER");
        require(oldAdmin != newAdmin, "OLD_NEW_ADMIN_SAME");
        require(!(acceptDefaultAdmin && renounceOldAdmin), "INVALID_PHASE");

        (string[] memory proxyNames, address[] memory proxies) = _proxyTargets();
        (string[] memory factoryNames, address[] memory factories) = _factoryTargets();
        _requireTargets(proxyNames, proxies);
        _requireTargets(factoryNames, factories);

        console2.log("=== TransferProtocolOwnership ===");
        console2.log("Old admin        :", oldAdmin);
        console2.log("New admin        :", newAdmin);
        console2.log("New beacon owner :", newBeaconOwner);
        console2.log("Accept new admin :", acceptDefaultAdmin);
        console2.log("Renounce old     :", renounceOldAdmin);

        if (acceptDefaultAdmin) {
            _requireReadyDefaultAdminTransfers(proxies, newAdmin);
            _startBroadcast(newAdmin);
            _acceptDefaultAdminTransfers(proxyNames, proxies, newAdmin);
            vm.stopBroadcast();
        } else if (renounceOldAdmin) {
            _requireNewAdminPresent(proxies, newAdmin);
            _startBroadcast(oldAdmin);
            _renounceOldAdmin(proxyNames, proxies, oldAdmin);
            vm.stopBroadcast();
        } else {
            _startBroadcast(oldAdmin);
            _grantNewAdmin(proxyNames, proxies, newAdmin);
            _transferBeaconOwners(factoryNames, factories, newBeaconOwner);
            vm.stopBroadcast();
        }

        _printVerification(proxyNames, proxies, oldAdmin, newAdmin, factoryNames, factories);
    }

    function _proxyTargets() internal view returns (string[] memory names, address[] memory targets) {
        names = new string[](8);
        targets = new address[](8);

        names[0] = "Vault";
        targets[0] = _envOr("TRANSFER_VAULT", "UPGRADE_INIT_VAULT_PROXY", "EXISTING_VAULT_PROXY");

        names[1] = "Gateway";
        targets[1] = _envOr("TRANSFER_GATEWAY", "UPGRADE_INIT_GATEWAY", "F_GATEWAY");

        names[2] = "Accountant";
        targets[2] = _envOr("TRANSFER_ACCOUNTANT", "UPGRADE_INIT_ACCOUNTANT", "F_ACCOUNTANT");

        names[3] = "StrategyController";
        targets[3] = _envOr("TRANSFER_CONTROLLER", "UPGRADE_INIT_CONTROLLER", "F_CONTROLLER_ADDRESS");

        names[4] = "SanctionsOracle";
        targets[4] = _envOr("TRANSFER_SANCTIONS_ORACLE", "F_SANCTIONS_ORACLE", "");

        names[5] = "AccountantExecutor";
        targets[5] = _envOr("TRANSFER_ACCOUNTANT_EXECUTOR", "UPGRADE_INIT_ACCOUNTANT_EXECUTOR", "F_ACCOUNTANT_EXECUTOR");

        names[6] = "OperatorExecutor";
        targets[6] = _envOr("TRANSFER_OPERATOR_EXECUTOR", "UPGRADE_INIT_OPERATOR_EXECUTOR", "F_OPERATOR_EXECUTOR");

        names[7] = "SubRedManagementAdapter";
        targets[7] = _envOr("TRANSFER_ADAPTER", "UPGRADE_INIT_ADAPTER_PROXY", "F_STRATEGY_ADAPTER_ADDRESS");
    }

    function _factoryTargets() internal view returns (string[] memory names, address[] memory targets) {
        names = new string[](6);
        targets = new address[](6);

        names[0] = "VaultFactory";
        targets[0] = _envOr("TRANSFER_VAULT_FACTORY", "UPGRADE_INIT_VAULT_FACTORY", "F_VAULT_FACTORY");

        names[1] = "GatewayFactory";
        targets[1] = _envOr("TRANSFER_GATEWAY_FACTORY", "F_GATEWAY_FACTORY", "");

        names[2] = "AccountantFactory";
        targets[2] = _envOr("TRANSFER_ACCOUNTANT_FACTORY", "F_ACCOUNTANT_FACTORY", "");

        names[3] = "StrategyControllerFactory";
        targets[3] = _envOr("TRANSFER_CONTROLLER_FACTORY", "F_STRATEGY_CONTROLLER_FACTORY", "");

        names[4] = "SanctionsOracleFactory";
        targets[4] = _envOr("TRANSFER_SANCTIONS_ORACLE_FACTORY", "F_SANCTIONS_ORACLE_FACTORY", "");

        names[5] = "SubRedManagementAdapterFactory";
        targets[5] = _envOr("TRANSFER_SUBRED_ADAPTER_FACTORY", "UPGRADE_INIT_SUBRED_ADAPTER_FACTORY", "");
    }

    function _grantNewAdmin(string[] memory names, address[] memory proxies, address newAdmin) internal {
        for (uint256 i; i < proxies.length; ++i) {
            if (_isDefaultAdminRules(proxies[i])) {
                IDefaultAdminRulesLike defaultAdminRules = IDefaultAdminRulesLike(proxies[i]);
                address currentDefaultAdmin = defaultAdminRules.defaultAdmin();
                if (currentDefaultAdmin == newAdmin) {
                    console2.log("Default admin already accepted:", names[i], newAdmin);
                    continue;
                }

                (address pendingAdmin, uint48 schedule) = defaultAdminRules.pendingDefaultAdmin();
                if (pendingAdmin == newAdmin) {
                    console2.log("Default admin already pending :", names[i], newAdmin);
                    console2.log("  schedule:", schedule);
                    continue;
                }
                require(pendingAdmin == address(0), "PENDING_ADMIN_EXISTS");

                defaultAdminRules.beginDefaultAdminTransfer(newAdmin);
                (, schedule) = defaultAdminRules.pendingDefaultAdmin();
                console2.log("Default admin transfer begun:", names[i], newAdmin);
                console2.log("  schedule:", schedule);
                continue;
            }

            IAccessControlLike proxy = IAccessControlLike(proxies[i]);
            if (proxy.hasRole(DEFAULT_ADMIN_ROLE, newAdmin)) {
                console2.log("Admin already granted:", names[i], newAdmin);
                continue;
            }
            proxy.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            console2.log("Admin granted        :", names[i], newAdmin);
        }
    }

    function _acceptDefaultAdminTransfers(string[] memory names, address[] memory proxies, address newAdmin) internal {
        for (uint256 i; i < proxies.length; ++i) {
            if (!_isDefaultAdminRules(proxies[i])) continue;

            IDefaultAdminRulesLike proxy = IDefaultAdminRulesLike(proxies[i]);
            if (proxy.defaultAdmin() == newAdmin) {
                console2.log("Default admin already accepted:", names[i], newAdmin);
                continue;
            }

            proxy.acceptDefaultAdminTransfer();
            console2.log("Default admin accepted:", names[i], newAdmin);
        }
    }

    function _transferBeaconOwners(string[] memory names, address[] memory factories, address newBeaconOwner) internal {
        for (uint256 i; i < factories.length; ++i) {
            IOwnableLike beacon = IBeaconFactoryLike(factories[i]).BEACON();
            address currentOwner = beacon.owner();
            if (currentOwner == newBeaconOwner) {
                console2.log("Beacon already owned:", names[i], newBeaconOwner);
                continue;
            }
            beacon.transferOwnership(newBeaconOwner);
            console2.log("Beacon owner moved  :", names[i], newBeaconOwner);
        }
    }

    function _renounceOldAdmin(string[] memory names, address[] memory proxies, address oldAdmin) internal {
        for (uint256 i; i < proxies.length; ++i) {
            if (_isDefaultAdminRules(proxies[i])) {
                console2.log("Default admin rules skip:", names[i]);
                continue;
            }

            IAccessControlLike proxy = IAccessControlLike(proxies[i]);
            if (!proxy.hasRole(DEFAULT_ADMIN_ROLE, oldAdmin)) {
                console2.log("Old admin absent    :", names[i], oldAdmin);
                continue;
            }
            proxy.renounceRole(DEFAULT_ADMIN_ROLE, oldAdmin);
            console2.log("Old admin renounced :", names[i], oldAdmin);
        }
    }

    function _requireNewAdminPresent(address[] memory proxies, address newAdmin) internal view {
        for (uint256 i; i < proxies.length; ++i) {
            require(IAccessControlLike(proxies[i]).hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "NEW_ADMIN_MISSING");
        }
    }

    function _requireReadyDefaultAdminTransfers(address[] memory proxies, address newAdmin) internal view {
        for (uint256 i; i < proxies.length; ++i) {
            if (!_isDefaultAdminRules(proxies[i])) continue;

            IDefaultAdminRulesLike proxy = IDefaultAdminRulesLike(proxies[i]);
            if (proxy.defaultAdmin() == newAdmin) continue;

            (address pendingAdmin, uint48 schedule) = proxy.pendingDefaultAdmin();
            require(pendingAdmin == newAdmin, "PENDING_ADMIN_MISMATCH");
            require(schedule != 0 && schedule < block.timestamp, "DEFAULT_ADMIN_TRANSFER_NOT_READY");
        }
    }

    function _printVerification(
        string[] memory proxyNames,
        address[] memory proxies,
        address oldAdmin,
        address newAdmin,
        string[] memory factoryNames,
        address[] memory factories
    ) internal view {
        console2.log("");
        console2.log("=========== Proxy admin verification ===========");
        for (uint256 i; i < proxies.length; ++i) {
            IAccessControlLike proxy = IAccessControlLike(proxies[i]);
            console2.log(proxyNames[i], proxies[i]);
            console2.log("  old admin:", proxy.hasRole(DEFAULT_ADMIN_ROLE, oldAdmin));
            console2.log("  new admin:", proxy.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));
            if (_isDefaultAdminRules(proxies[i])) {
                IDefaultAdminRulesLike defaultAdminRules = IDefaultAdminRulesLike(proxies[i]);
                (address pendingAdmin, uint48 schedule) = defaultAdminRules.pendingDefaultAdmin();
                console2.log("  default admin:", defaultAdminRules.defaultAdmin());
                console2.log("  pending admin:", pendingAdmin);
                console2.log("  pending schedule:", schedule);
            }
        }

        console2.log("");
        console2.log("=========== Beacon owner verification ===========");
        for (uint256 i; i < factories.length; ++i) {
            IOwnableLike beacon = IBeaconFactoryLike(factories[i]).BEACON();
            console2.log(factoryNames[i], address(beacon));
            console2.log("  owner:", beacon.owner());
        }
    }

    function _requireTargets(string[] memory names, address[] memory targets) internal pure {
        for (uint256 i; i < targets.length; ++i) {
            require(targets[i] != address(0), string.concat(names[i], "_ZERO"));
        }
    }

    function _requireNonZero(address value, string memory envName) internal pure {
        require(value != address(0), string.concat(envName, "_ZERO"));
    }

    function _isDefaultAdminRules(address target) internal view returns (bool) {
        try IDefaultAdminRulesLike(target).defaultAdmin() returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _startBroadcast(address expectedSender) internal {
        address configuredSender = vm.envOr("F_SENDER", address(0));
        if (configuredSender != address(0)) {
            require(configuredSender == expectedSender, "F_SENDER_UNEXPECTED");
            vm.startBroadcast(configuredSender);
            return;
        }

        vm.startBroadcast();
    }

    function _envOr(string memory primary, string memory fallback1, string memory fallback2)
        internal
        view
        returns (address)
    {
        address value = vm.envOr(primary, address(0));
        if (value != address(0)) return value;

        if (bytes(fallback1).length != 0) {
            value = vm.envOr(fallback1, address(0));
            if (value != address(0)) return value;
        }

        if (bytes(fallback2).length != 0) {
            value = vm.envOr(fallback2, address(0));
            if (value != address(0)) return value;
        }

        return address(0);
    }

    function _envBool(string memory name, bool defaultValue) internal view returns (bool) {
        string memory defaultString = defaultValue ? "true" : "false";
        string memory value = vm.envOr(name, defaultString);
        bytes32 valueHash = keccak256(bytes(value));

        if (valueHash == keccak256(bytes("true")) || valueHash == keccak256(bytes("1"))) return true;
        if (valueHash == keccak256(bytes("false")) || valueHash == keccak256(bytes("0")) || bytes(value).length == 0) {
            return false;
        }

        revert("INVALID_BOOL");
    }
}
