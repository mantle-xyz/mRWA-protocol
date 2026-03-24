// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/adapters/IStrategyAdapter.sol";
import {IMantleVaultGateway} from "../interfaces/vault/IMantleVaultGateway.sol";
import {MantleYieldVaultAdminModule} from "./modules/MantleYieldVaultAdminModule.sol";
import {MantleYieldVaultControllerModule} from "./modules/MantleYieldVaultControllerModule.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MantleYieldVault (ERC-4626 + ERC-7540 Async Redemption, Beacon Proxy Upgradeable)
 * @notice Production-grade RWA asset vault.
 *   - Deposits: synchronous (ERC-4626 deposit)
 *   - Instant redemptions: sync redeem when FreeCash is sufficient
 *   - Async redemptions: ERC-7540 request -> process -> settle
 */
contract MantleYieldVault is MantleYieldVaultControllerModule, MantleYieldVaultAdminModule {
    using Math for uint256;

    function initialize(InitParams calldata params) external override initializer {
        _initializeStorage(params);
    }

    // =============================================================
    // ERC-7540: Async Redemption Requests
    // =============================================================

    function _requestRedeem(address owner, uint256 shares) internal returns (uint256 requestId) {
        if (shares == 0) revert Vault__ZeroAmount();

        uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 fee = grossAssets.mulDiv(redemptionFeeBps, FEE_BASIS, Math.Rounding.Ceil);
        uint256 estimatedAssets = grossAssets - fee;

        if (estimatedAssets < minRedeemAmount) revert Vault__BelowMinRedeem(estimatedAssets, minRedeemAmount);

        _burn(owner, shares);

        totalLockedShares += shares;
        _pendingShares[owner] += shares;

        requestId = nextRequestId++;
        requests[requestId] = RedemptionRequest({
            id: requestId,
            owner: owner,
            shares: shares,
            estimatedAssets: estimatedAssets,
            settledAssets: 0,
            timestamp: block.timestamp,
            status: RequestStatus.PENDING
        });

        emit RedeemRequest(owner, requestId, shares, estimatedAssets);
    }

    function requestRedeemFor(address caller, address owner, uint256 shares)
        external
        onlyGateway
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        return _requestRedeem(owner, shares);
    }

    function routeSanctionedShares(address caller, address owner, uint256 shares)
        external
        onlyGateway
        nonReentrant
        whenNotPaused
    {
        if (shares == 0) revert Vault__ZeroAmount();
        if (caller != owner) _spendAllowance(owner, caller, shares);
        address safe = IMantleVaultGateway(gateway).sanctionSafe();
        if (safe == address(0)) revert Vault__ZeroAddress();
        super._update(owner, safe, shares);
        emit SactionSafeIn(owner, asset(), shares);
    }

    /// @notice User interactions are exposed on MantleVaultGateway to keep this vault lean.
    function requestRedeem(uint256) external pure returns (uint256) {
        revert Vault__NotAuthorized();
    }

    function pendingRedeemRequest(address account) external view returns (uint256) {
        return _pendingShares[account];
    }

    // =============================================================
    // ERC-4626 Synchronous Redemption (atomic when FreeCash sufficient, reverts otherwise)
    // =============================================================

    function redeem(uint256, address, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert Vault__NotAuthorized();
    }

    function withdraw(uint256, address, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert Vault__NotAuthorized();
    }

    function redeemFor(address caller, uint256 shares, address receiver, address owner)
        external
        onlyGateway
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
        assets = previewRedeem(shares);
        _withdraw(caller, receiver, owner, assets, shares);
    }

    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 fee = grossAssets.mulDiv(redemptionFeeBps, FEE_BASIS, Math.Rounding.Ceil);
        return grossAssets - fee;
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (redemptionFeeBps >= FEE_BASIS) return type(uint256).max;
        uint256 grossAssets = assets.mulDiv(FEE_BASIS, FEE_BASIS - redemptionFeeBps, Math.Rounding.Ceil);
        return _convertToShares(grossAssets, Math.Rounding.Ceil);
    }

    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        uint256 shares = balanceOf(owner);
        uint256 freeCash = getFreeCash();
        uint256 assetsForAll = previewRedeem(shares);
        if (assetsForAll <= freeCash) return shares;
        uint256 grossFromCash = redemptionFeeBps > 0
            ? freeCash.mulDiv(FEE_BASIS, FEE_BASIS - redemptionFeeBps, Math.Rounding.Floor)
            : freeCash;
        return _convertToShares(grossFromCash, Math.Rounding.Floor);
    }

    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        uint256 redeemable = previewRedeem(balanceOf(owner));
        uint256 freeCash = getFreeCash();
        return redeemable < freeCash ? redeemable : freeCash;
    }

    // =============================================================
    // FreeCash Query & Withdrawal Safety Check
    // =============================================================

    function getFreeCash() public view returns (uint256) {
        uint256 physicalBalance = IERC20(asset()).balanceOf(address(this));
        uint256 floatingLocked = previewRedeem(totalLockedShares);
        if (physicalBalance <= floatingLocked) return 0;
        return physicalBalance - floatingLocked;
    }

    function getTokenInfos() external view returns (tokenInfo[] memory) {
        uint256 len = adapters.length;
        tokenInfo[] memory infos = new tokenInfo[](len + 1);
        infos[0] = tokenInfo(
            asset(),
            IERC20(asset()).balanceOf(address(this)) + totalRedeemInFlight,
            IERC20(asset()).balanceOf(address(this)) + totalRedeemInFlight
        );
        for (uint256 i = 0; i < len; i++) {
            IStrategyAdapter adapter = IStrategyAdapter(adapters[i]);
            IERC20 token = IERC20(adapter.posToken());
            uint256 tokenAmount = adapterInvestInFlightTokens[adapters[i]] + token.balanceOf(address(this));
            uint256 priceE18 = adapter.getPosTokenPrice();
            uint256 usdcAmount = tokenAmount.mulDiv(priceE18, 1e6, Math.Rounding.Floor);
            infos[i + 1] = tokenInfo(adapter.posToken(), tokenAmount, usdcAmount);
        }
        return infos;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        uint256 freeCash = getFreeCash();
        if (assets > freeCash) revert Vault__InsufficientFreeCash(assets, freeCash);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // =============================================================
    // ERC-4626 Deposits (with pause guard)
    // =============================================================

    function deposit(uint256, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert Vault__NotAuthorized();
    }

    function mint(uint256, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert Vault__NotAuthorized();
    }

    function depositFor(address caller, uint256 assets, address receiver)
        external
        onlyGateway
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets < minDepositAmount) revert Vault__BelowMinDeposit(assets, minDepositAmount);
        shares = previewDeposit(assets);
        _deposit(caller, receiver, assets, shares);
    }

    // =============================================================
    // ERC-4626 Pricing Overrides
    // =============================================================

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this)) + totalInvestInFlight + totalRedeemInFlight;
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IStrategyAdapter(adapters[i]).totalValue();
        }
        uint256 floatingLocked = previewRedeem(totalLockedShares);
        if (total <= floatingLocked) return 0;
        return total - floatingLocked;
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(_currentExchangeRate(), 1e18, rounding);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(1e18, _currentExchangeRate(), rounding);
    }

    function share() external view returns (address) {
        return address(this);
    }

    function exchangeRate() external view returns (uint256) {
        return _currentExchangeRate();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlDefaultAdminRulesUpgradeable, MantleYieldVaultAdminModule)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
