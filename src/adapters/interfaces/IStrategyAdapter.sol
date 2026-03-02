// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyAdapter {
    /**
     * @notice Strategy name (e.g. "Ondo OUSG Adapter")
     */
    function name() external view returns (string memory);

    /**
     * @notice Underlying asset address (e.g. OUSG token address)
     */
    function asset() external view returns (address);

    /**
     * @notice Vault that custodies funds and credentials
     */
    function vault() external view returns (address);

    /**
     * @notice Total value held by this strategy (denominated in USDC, 6 decimals)
     * @dev Used by Accountant for NAV calculation and Controller for allocation ratios
     */
    function totalValue() external view returns (uint256);

    /**
     * @notice Invest: purchase underlying assets with USDC
     * @param amount USDC amount to invest
     * @param receiver Address to receive the underlying shares/position
     * @return sharesOrPos Amount of underlying shares obtained
     */
    function deposit(uint256 amount, address receiver) external returns (uint256 sharesOrPos);

    /**
     * @notice Synchronous withdrawal: convert underlying back to USDC (T+0 assets, atomic)
     * @param amount USDC-equivalent amount to withdraw
     * @param receiver Address to receive the USDC
     * @return actualUSDC Actual USDC amount received
     */
    function withdrawSync(uint256 amount, address receiver) external returns (uint256 actualUSDC);

    /**
     * @notice Async redemption request: initiate T+N redemption (underlying requires settlement time)
     * @param amount USDC-equivalent amount to redeem
     * @param receiver Address to ultimately receive the USDC
     * @return requestId Async request identifier
     */
    function requestRedeemAsync(uint256 amount, address receiver) external returns (bytes32 requestId);

    /**
     * @notice Emergency action
     * @dev Allows Admin to emergency-withdraw funds when the underlying protocol is paused or compromised
     */
    function panic() external;
}
