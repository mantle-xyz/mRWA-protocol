// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle is ISanctionsOracle {
    mapping(address => bool) public sanctioned;
    mapping(address => bool) public whitelisted;

    function initialize(address, address) external override {}

    function isSanctioned(address account) external view override returns (bool) {
        return sanctioned[account];
    }

    function isWhitelisted(address account) external view override returns (bool) {
        return whitelisted[account];
    }

    function setSanctioned(address account, bool status) external {
        sanctioned[account] = status;
    }

    function setWhitelisted(address account, bool status) external {
        whitelisted[account] = status;
    }

    function totalSanctionedCount() external pure override returns (uint256) {
        return 0;
    }

    function totalWhitelistedCount() external pure override returns (uint256) {
        return 0;
    }

    function lastUpdateTimestamp() external pure override returns (uint256) {
        return 0;
    }

    function batchNonce() external pure override returns (uint256) {
        return 0;
    }

    function updateSanctionStatus(address, bool) external override {}
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address, bool) external override {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}

    function MAX_BATCH_SIZE() external pure override returns (uint256) {
        return 200;
    }
}

contract MockAccountant {
    uint256 public exchangeRate = 1e18;

    function getRate() external view returns (uint256) {
        return exchangeRate;
    }

    function getRateSafe() external view returns (uint256) {
        return exchangeRate;
    }

    function managementFeeRate() external pure returns (uint32) {
        return 0;
    }

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }
}

// ---------------------------------------------------------------------------
// QA Test: Vault Access Scenarios
// ---------------------------------------------------------------------------

contract VaultAccessQATest is Test {
    MockUSDC6 internal usdc;
    MockSanctionsOracle internal sanctionsOracle;
    MockAccountant internal accountant;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;

    address internal adminAddr = makeAddr("admin");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafeAddr = makeAddr("sanctionSafe");
    address internal user = makeAddr("user");
    address internal nonGateway = makeAddr("nonGateway");

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"用户入口与路由场景";
    string private _caseId;
    string private _caseName;
    string private _buf;

    function _logCase(string memory id, string memory name) internal {
        _caseId = id;
        _caseName = name;
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name));
        _step("----------------------------------------");
    }

    function _step(string memory msg) internal {
        console2.log(msg);
        _buf = string.concat(_buf, msg, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    function setUp() public {
        usdc = new MockUSDC6();
        sanctionsOracle = new MockSanctionsOracle();
        accountant = new MockAccountant();

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        VaultFactory factory = new VaultFactory(address(impl), adminAddr);
        GatewayFactory gatewayFactory = new GatewayFactory(address(gatewayImpl), adminAddr);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: adminAddr,
            gateway: gatewayAddr,
            controller: controllerAddr,
            accountant: address(accountant),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 0,
            minRedeemAmount: 0,
            minDepositAmount: 0
        });
        vm.prank(adminAddr);
        vault.initialize(params);

        vm.prank(adminAddr);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(sanctionsOracle)),
                sanctionSafe: sanctionSafeAddr,
                admin: adminAddr,
                syncRedeemDisabled: false
            })
        );
    }

    // -----------------------------------------------------------------------
    // 1. test_UserDirectDeposit_Rejected
    // -----------------------------------------------------------------------

    function test_UserDirectDeposit_Rejected() public {
        _logCase(
            "test_UserDirectDeposit_Rejected",
            unicode"用户直调 `vault.deposit` 被拒绝"
        );

        _step("[Step 1] User directly calls vault.deposit(assets, receiver)");
        vm.prank(user);
        vm.expectRevert(IMantleYieldVault.Vault__NotAuthorized.selector);
        vault.deposit(1000e6, user);
        _step("  PASS: Transaction reverted with Vault__NotAuthorized");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_UserDirectMint_Rejected
    // -----------------------------------------------------------------------

    function test_UserDirectMint_Rejected() public {
        _logCase(
            "test_UserDirectMint_Rejected",
            unicode"用户直调 `vault.mint` 被拒绝"
        );

        _step("[Step 1] User directly calls vault.mint(shares, receiver)");
        vm.prank(user);
        vm.expectRevert(IMantleYieldVault.Vault__NotAuthorized.selector);
        vault.mint(1000e18, user);
        _step("  PASS: Transaction reverted with Vault__NotAuthorized");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_UserDirectRedeemWithdraw_Rejected
    // -----------------------------------------------------------------------

    function test_UserDirectRedeemWithdraw_Rejected() public {
        _logCase(
            "test_UserDirectRedeemWithdraw_Rejected",
            unicode"用户直调 `vault.redeem / vault.withdraw` 被拒绝"
        );

        _step("[Step 1] User directly calls vault.redeem(...)");
        vm.prank(user);
        vm.expectRevert(IMantleYieldVault.Vault__NotAuthorized.selector);
        vault.redeem(1000e18, user, user);
        _step("  PASS: vault.redeem reverted with Vault__NotAuthorized");

        _step("[Step 2] User directly calls vault.withdraw(...)");
        vm.prank(user);
        vm.expectRevert(IMantleYieldVault.Vault__NotAuthorized.selector);
        vault.withdraw(1000e6, user, user);
        _step("  PASS: vault.withdraw reverted with Vault__NotAuthorized");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_UserDirectRequestRedeem_Rejected
    // -----------------------------------------------------------------------

    function test_UserDirectRequestRedeem_Rejected() public {
        _logCase(
            "test_UserDirectRequestRedeem_Rejected",
            unicode"用户直调 `vault.requestRedeem` 被拒绝"
        );

        _step("[Step 1] User directly calls vault.requestRedeem(shares)");
        vm.prank(user);
        vm.expectRevert(IMantleYieldVault.Vault__NotAuthorized.selector);
        vault.requestRedeem(1000e18);
        _step("  PASS: Transaction reverted with Vault__NotAuthorized");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_NonGatewayDepositFor_Rejected
    // -----------------------------------------------------------------------

    function test_NonGatewayDepositFor_Rejected() public {
        _logCase(
            "test_NonGatewayDepositFor_Rejected",
            unicode"非 Gateway 账户直调 `depositFor` 被拒绝"
        );

        _step("[Step 1] Non-Gateway address calls vault.depositFor(...)");
        vm.prank(nonGateway);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.depositFor(nonGateway, 1000e6, nonGateway);
        _step("  PASS: Transaction reverted with Vault__OnlyGateway");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_NonGatewayRedeemFor_Rejected
    // -----------------------------------------------------------------------

    function test_NonGatewayRedeemFor_Rejected() public {
        _logCase(
            "test_NonGatewayRedeemFor_Rejected",
            unicode"非 Gateway 账户直调 `redeemFor` 被拒绝"
        );

        _step("[Step 1] Non-Gateway address calls vault.redeemFor(...)");
        vm.prank(nonGateway);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.redeemFor(nonGateway, 1000e18, nonGateway, nonGateway);
        _step("  PASS: Transaction reverted with Vault__OnlyGateway");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_NonGatewayRequestRedeemFor_Rejected
    // -----------------------------------------------------------------------

    function test_NonGatewayRequestRedeemFor_Rejected() public {
        _logCase(
            "test_NonGatewayRequestRedeemFor_Rejected",
            unicode"非 Gateway 账户直调 `requestRedeemFor` 被拒绝"
        );

        _step("[Step 1] Non-Gateway address calls vault.requestRedeemFor(...)");
        vm.prank(nonGateway);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.requestRedeemFor(nonGateway, nonGateway, 1000e18);
        _step("  PASS: Transaction reverted with Vault__OnlyGateway");

        _logPass();
    }
}
