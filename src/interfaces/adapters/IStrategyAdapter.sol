// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyAdapter {
    /**
     * @notice 策略名称 (e.g. "Ondo OUSG Adapter")
     */
    function name() external view returns (string memory);

    /**
     * @notice 底层资产地址 (e.g. OUSG token address)
     */
    function asset() external view returns (address);

    /**
     * @notice 资金与凭证托管 Vault
     */
    function vault() external view returns (address);

    /**
     * @notice 策略持有的总价值 (以 USDC 为计价单位，6位精度)
     * @dev 用于 Accountant 计算 NAV 和 Controller 计算占比
     */
    function totalValue() external view returns (uint256);

    /**
     * @notice 存款 (Invest) 仅 Controller 调用
     * @param amountUSDC 要存入的 USDC 数量
     * @param receiver 份额接收地址
     * @return sharesOrPos 获得的底层份额数量
     */
    function deposit(uint256 amountUSDC, address receiver) external returns (uint256 sharesOrPos);

    /// @notice 同步赎回（同交易完成）
    function redeemSync(uint256 amountUSDC, address receiver) external returns (uint256 actualUSDC);

    /// @notice 发起异步赎回请求（T+N 等场景）
    function requestRedeem(uint256 amountUSDC, address receiver) external returns (bytes32 requestId);

    /// @notice 领取异步赎回结果
    function claimRedeem(bytes32 requestId, address receiver) external returns (uint256 actualUSDC);

    /**
     * @notice 紧急操作
     * @dev 当底层协议暂停或被黑时，允许 Admin 紧急提取资金
     */
    function panic() external;
}
