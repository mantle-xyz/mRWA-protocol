// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "./IMantleYieldVault.sol";

interface IMantleVaultGateway {
    struct InitParams {
        address vault;
        ISanctionsOracle sanctionsOracle;
        address sanctionSafe;
        address admin;
        bool syncRedeemDisabled;
    }

    error Gateway__NotWhitelisted(address account);

    event SyncRedeemDisabledUpdated(bool disabled);
    event SanctionsOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event SanctionSafeUpdated(address indexed oldSanctionSafe, address indexed newSanctionSafe);
    event WhitelistEnabledUpdated(bool enabled);

    function initialize(InitParams calldata params) external;

    function vault() external view returns (IMantleYieldVault);
    function deposit(uint256 assets) external returns (uint256 shares);
    function redeem(uint256 shares) external returns (uint256 assets);
    function requestRedeem(uint256 shares) external returns (uint256 requestId);
    function syncRedeemDisabled() external view returns (bool);
    function sanctionsOracle() external view returns (ISanctionsOracle);
    function sanctionSafe() external view returns (address);
    function setSyncRedeemDisabled(bool disabled) external;
    function setSanctionsOracle(address newOracle) external;
    function setSanctionSafe(address newSanctionSafe) external;
    function isSanctionSafe(address account) external view returns (bool);
    function isSanctioned(address account) external view returns (bool);
    function isWhitelisted(address account) external view returns (bool);
    function whitelistEnabled() external view returns (bool);
    function setWhitelistEnabled(bool enabled) external;
    function enforceShareTransfer(address from, address to) external view;
    function resolveRedemptionReceiver(address owner) external view returns (address receiver, bool sanctioned);

    function maxDeposit(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function managementFeeRate() external view returns (uint256);
    function redemptionFeeBps() external view returns (uint256);
    function minRedeemAmount() external view returns (uint256);
    function exchangeRate() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function getTokenInfos() external view returns (IMantleYieldVault.tokenInfo[] memory);
    function getFreeCash() external view returns (uint256);
}
