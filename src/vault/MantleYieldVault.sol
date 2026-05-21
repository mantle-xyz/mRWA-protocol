// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/adapters/IStrategyAdapter.sol";
import {IMantleVaultGateway} from "../interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVaultAdminModule} from "./modules/MantleYieldVaultAdminModule.sol";
import {MantleYieldVaultControllerModule} from "./modules/MantleYieldVaultControllerModule.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata params) external override initializer {
        __MantleYieldVaultStorage_init(params);
    }

    // =============================================================
    // ERC-7540: Async Redemption Requests
    // =============================================================

    function _requestRedeem(address owner, uint256 shares) internal returns (uint256 requestId) {
        if (shares == 0) revert Vault__ZeroAmount();

        if (shares < minRedeemAmount) revert Vault__BelowMinRedeem(shares, minRedeemAmount);
        if (redeemDailyRemaining < shares) {
            revert Vault__RedeemDailyCapExceeded(shares, redeemDailyRemaining);
        }
        redeemDailyRemaining -= shares;

        uint256 treasuryShare = shares.mulDiv(redemptionFeeBps, FEE_BASIS, Math.Rounding.Ceil);
        uint256 netShares = shares - treasuryShare;
        uint256 estimatedAssets = _convertToAssets(netShares, Math.Rounding.Floor);
        if (estimatedAssets == 0) revert Vault__ZeroAssets();

        if (treasuryShare > 0) {
            _update(owner, treasury, treasuryShare);
            emit FeeSharesReceived(treasury, treasuryShare, FeeType.Redemption);
        }
        _burn(owner, netShares);

        totalLockedShares += netShares;
        pendingRequestCount++;
        _pendingShares[owner] += netShares;

        requestId = nextRequestId++;
        requests[requestId] = RedemptionRequest({
            id: requestId,
            owner: owner,
            shares: netShares,
            feeShares: treasuryShare,
            estimatedAssets: estimatedAssets,
            settledAssets: 0,
            timestamp: block.timestamp,
            status: RequestStatus.PENDING
        });

        emit RedeemRequest(owner, requestId, netShares, estimatedAssets, treasuryShare);
    }

    function requestRedeem(address owner, uint256 shares)
        external
        onlyGateway
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        return _requestRedeem(owner, shares);
    }

    function routeSanctionedShares(address owner, uint256 shares) external onlyGateway nonReentrant whenNotPaused {
        if (shares == 0) revert Vault__ZeroAmount();
        address safe = IMantleVaultGateway(gateway).sanctionSafe();
        if (safe == address(0)) revert Vault__ZeroAddress();
        _update(owner, safe, shares);
        emit SanctionSafeIn(owner, address(this), shares);
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

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
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
        if (redeemDailyRemaining < shares) {
            revert Vault__RedeemDailyCapExceeded(shares, redeemDailyRemaining);
        }
        redeemDailyRemaining -= shares;
        uint256 treasuryShare = shares.mulDiv(redemptionFeeBps, FEE_BASIS, Math.Rounding.Ceil);
        uint256 netShares = shares - treasuryShare;
        assets = _convertToAssets(netShares, Math.Rounding.Floor);
        if (assets == 0) revert Vault__ZeroAssets();
        if (treasuryShare > 0) {
            _update(owner, treasury, treasuryShare);
            emit FeeSharesReceived(treasury, treasuryShare, FeeType.Redemption);
        }
        _withdraw(owner, receiver, owner, assets, netShares);
    }

    function withdraw(uint256, address, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert Vault__NotAuthorized();
    }

    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 treasuryShare = shares.mulDiv(redemptionFeeBps, FEE_BASIS, Math.Rounding.Ceil);
        uint256 netShares = shares - treasuryShare;
        return _convertToAssets(netShares, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (redemptionFeeBps >= FEE_BASIS) return type(uint256).max;
        uint256 grossAssets = assets.mulDiv(FEE_BASIS, FEE_BASIS - redemptionFeeBps, Math.Rounding.Ceil);
        return _convertToShares(grossAssets, Math.Rounding.Ceil);
    }

    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        if (depositDailyRemaining > 0 && depositDailyRemaining < minDepositAmount) return 0;
        return depositDailyRemaining;
    }

    function maxMint(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 maxAssets = maxDeposit(owner);
        if (maxAssets >= type(uint256).max) return type(uint256).max;
        if (maxAssets == 0) return 0;
        return _convertToShares(maxAssets, Math.Rounding.Floor);
    }

    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        uint256 shares = balanceOf(owner);

        // Constraint 1: freeCash → max redeemable shares (existing logic)
        uint256 freeCash = getFreeCash();
        uint256 assetsForAll = previewRedeem(shares);
        uint256 cashLimited = shares;
        if (assetsForAll > freeCash) {
            if (redemptionFeeBps >= FEE_BASIS) return 0;
            uint256 grossFromCash = redemptionFeeBps > 0
                ? freeCash.mulDiv(FEE_BASIS, FEE_BASIS - redemptionFeeBps, Math.Rounding.Floor)
                : freeCash;
            cashLimited = _convertToShares(grossFromCash, Math.Rounding.Floor);
        }

        // Take min of all constraints
        uint256 result = cashLimited < redeemDailyRemaining ? cashLimited : redeemDailyRemaining;
        if (result > shares) result = shares;
        if (result > 0 && result < minRedeemAmount) return 0;
        return result;
    }

    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        uint256 redeemable = previewRedeem(balanceOf(owner));
        uint256 freeCash = getFreeCash();
        uint256 ceiling = redeemable < freeCash ? redeemable : freeCash;
        if (redeemDailyRemaining < type(uint256).max) {
            uint256 capAssets = previewRedeem(redeemDailyRemaining);
            if (capAssets < ceiling) ceiling = capAssets;
        }
        return ceiling;
    }

    // =============================================================
    // FreeCash Query & Withdrawal Safety Check
    // =============================================================

    function getFreeCash() public view returns (uint256) {
        uint256 physicalBalance = IERC20(asset()).balanceOf(address(this));
        uint256 floatingLocked = _convertToAssets(totalLockedShares, Math.Rounding.Ceil);
        return physicalBalance > floatingLocked ? physicalBalance - floatingLocked : 0;
    }

    function getCashDeficit() public view returns (uint256) {
        uint256 physicalBalance = IERC20(asset()).balanceOf(address(this));
        uint256 floatingLocked = _convertToAssets(totalLockedShares, Math.Rounding.Ceil);
        return floatingLocked > physicalBalance ? floatingLocked - physicalBalance : 0;
    }

    function getTokenInfos() external view returns (tokenInfo[] memory) {
        uint256 len = adapters.length;
        uint256 assetScale = 10 ** IERC20Metadata(asset()).decimals();
        tokenInfo[] memory infos = new tokenInfo[](len + 1);
        infos[0] = tokenInfo(
            asset(),
            IERC20(asset()).balanceOf(address(this)) + totalRedeemInFlight,
            IERC20(asset()).balanceOf(address(this)) + totalRedeemInFlight
        );
        for (uint256 i = 0; i < len; i++) {
            IStrategyAdapter adapter = IStrategyAdapter(adapters[i]);
            address posToken = adapter.posToken();
            uint256 tokenScale = 10 ** IERC20Metadata(posToken).decimals();
            uint256 tokenAmount = adapterInvestInFlightTokens[adapters[i]] + IERC20(posToken).balanceOf(address(this));
            uint256 priceE18 = adapter.getPosTokenPrice();
            uint256 stableAmount = tokenAmount.mulDiv(priceE18, 1e18, Math.Rounding.Floor)
                .mulDiv(assetScale, tokenScale, Math.Rounding.Floor);
            infos[i + 1] = tokenInfo(posToken, tokenAmount, stableAmount);
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

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        onlyGateway
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets < minDepositAmount) revert Vault__BelowMinDeposit(assets, minDepositAmount);
        if (assets > depositDailyRemaining) {
            revert Vault__DepositDailyCapExceeded(assets, depositDailyRemaining);
        }
        depositDailyRemaining -= assets;
        shares = previewDeposit(assets);
        if (shares == 0) revert Vault__ZeroShares();
        _deposit(receiver, receiver, assets, shares);
    }

    function mint(uint256, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert Vault__NotAuthorized();
    }

    // =============================================================
    // ERC-4626 Pricing Overrides
    // =============================================================

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this)) + totalInvestInFlight + totalRedeemInFlight;
        uint256 assetScale = 10 ** IERC20Metadata(asset()).decimals();
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            IStrategyAdapter adapter = IStrategyAdapter(adapters[i]);
            uint256 priceE18 = adapter.getPosTokenPrice();
            address posToken = adapter.posToken();
            uint256 tokenScale = 10 ** IERC20Metadata(posToken).decimals();
            uint256 tokenBalance = IERC20(posToken).balanceOf(address(this));
            total += tokenBalance.mulDiv(priceE18, 1e18, Math.Rounding.Floor)
                .mulDiv(assetScale, tokenScale, Math.Rounding.Floor);
        }
        uint256 floatingLocked = _convertToAssets(totalLockedShares, Math.Rounding.Ceil);
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
