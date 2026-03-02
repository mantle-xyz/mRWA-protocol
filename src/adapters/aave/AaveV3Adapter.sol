// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAdapter} from "../base/BaseAdapter.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @notice Sync-first adapter for Aave V3.
 * @dev Vault keeps strategy credentials (aUSDC). Controller orchestrates transfers.
 */
contract AaveV3Adapter is BaseAdapter {
    using SafeERC20 for IERC20;

    IAavePool public immutable POOL;
    IERC20 public immutable aUSDC;

    constructor(
        address usdc,
        address vault_,
        address pool,
        address ausdc,
        address admin,
        address controller,
        address operator
    ) BaseAdapter(usdc, vault_, admin, controller, operator) {
        POOL = IAavePool(pool);
        aUSDC = IERC20(ausdc);
    }

    function name() external pure override returns (string memory) {
        return "AaveV3Adapter";
    }

    function totalValue() external view override returns (uint256) {
        // Adapter in-flight USDC + Vault-held aUSDC position.
        return USDC.balanceOf(address(this)) + aUSDC.balanceOf(VAULT);
    }

    function deposit(uint256 amountUSDC, address) external override onlyController whenNotPaused returns (uint256) {
        USDC.forceApprove(address(POOL), amountUSDC);
        POOL.supply(address(USDC), amountUSDC, VAULT, 0);
        return amountUSDC;
    }

    function redeemSync(uint256 amountUSDC, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (uint256 actualUSDC)
    {
        actualUSDC = POOL.withdraw(address(USDC), amountUSDC, receiver);
    }

    function requestRedeem(uint256, address) external pure override returns (bytes32) {
        revert Unsupported();
    }

    function claimRedeem(bytes32, address) external pure override returns (uint256) {
        revert Unsupported();
    }

    function execute(bytes calldata) external override onlyOperator returns (bytes32) {
        revert Unsupported();
    }

    function panic() external override onlyController {
        paused = true;
        emit Paused(true);
        USDC.forceApprove(address(POOL), 0);
    }
}
