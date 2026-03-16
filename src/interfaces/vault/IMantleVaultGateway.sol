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

    event SyncRedeemDisabledUpdated(bool disabled);
    event SanctionsOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event SanctionSafeUpdated(address indexed oldSanctionSafe, address indexed newSanctionSafe);

    function initialize(InitParams calldata params) external;

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function syncRedeemDisabled() external view returns (bool);
    function sanctionsOracle() external view returns (ISanctionsOracle);
    function sanctionSafe() external view returns (address);
    function setSyncRedeemDisabled(bool disabled) external;
    function setSanctionsOracle(address newOracle) external;
    function setSanctionSafe(address newSanctionSafe) external;
    function isSanctionSafe(address account) external view returns (bool);
    function isSanctioned(address account) external view returns (bool);
    function enforceShareTransfer(address from, address to) external view;
    function resolveRedemptionReceiver(address owner) external view returns (address receiver, bool sanctioned);

    function maxMint(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function maxDeposit(address owner) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function managementFeeRate() external view returns (uint256);
    function redemptionFeeBps() external view returns (uint256);
    function exchangeRate() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function getTokenInfos() external view returns (IMantleYieldVault.tokenInfo[] memory);
}
