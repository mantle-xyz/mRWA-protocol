// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Minimal mocks
// ---------------------------------------------------------------------------

contract MockUSDC_GAC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_GAC is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _whitelisted;

    function initialize(address, address) external {}
    function isSanctioned(address account) external view returns (bool) { return _sanctioned[account]; }
    function isWhitelisted(address account) external view returns (bool) { return _whitelisted[account]; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function updateSanctionStatus(address account, bool sanctioned) external { _sanctioned[account] = sanctioned; }
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address account, bool whitelisted) external { _whitelisted[account] = whitelisted; }
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

// ---------------------------------------------------------------------------
// QA Test: Gateway Admin Configuration
// ---------------------------------------------------------------------------

contract GatewayAdminConfigQATest is Test {
    MockUSDC_GAC internal usdc;
    MockSanctionsOracle_GAC internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal user = makeAddr("user");
    address internal nonAdmin = makeAddr("nonAdmin");

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Gateway 管理配置场景";
    string private _buf;

    function _logCase(string memory id, string memory name_) internal {
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name_));
        _step("----------------------------------------");
    }

    function _step(string memory msg_) internal {
        console2.log(msg_);
        _buf = string.concat(_buf, msg_, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    // -----------------------------------------------------------------------
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_GAC();
        oracle = new MockSanctionsOracle_GAC();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();

        vault = MantleYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1),
                controller: admin,
                accountant: address(1),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            }))
        )));

        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin))
        )));

        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(ctrlImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault), admin, address(executor), admin, 1000, 200, 0
            ))
        )));

        gateway = MantleVaultGateway(address(new ERC1967Proxy(
            address(gwImpl),
            abi.encodeCall(MantleVaultGateway.initialize, IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            }))
        )));

        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        // Fund user
        usdc.mint(user, 1_000_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =======================================================================
    // 1. setSyncRedeemDisabled: admin 开启/关闭同步赎回开关
    // =======================================================================

    function test_SetSyncRedeemDisabled_Toggle() public {
        _logCase("test_SetSyncRedeemDisabled_Toggle", unicode"admin 开启/关闭同步赎回开关，验证 redeem 行为变化");

        _step("[Step 1] User deposits");
        vm.prank(user);
        gateway.deposit(1000e6);

        _step("[Step 2] Sync redeem works when disabled=false (default)");
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        uint256 assets = gateway.redeem(shares / 2);
        assertGt(assets, 0, "sync redeem should work when enabled");

        _step("[Step 3] Admin disables sync redeem");
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);
        assertTrue(gateway.syncRedeemDisabled(), "should be disabled");

        _step("[Step 4] Sync redeem should revert");
        uint256 remainingShares = vault.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(IMantleYieldVault.Vault__SyncRedeemDisabled.selector);
        gateway.redeem(remainingShares);
        _step("  redeem reverted with Vault__SyncRedeemDisabled");

        _step("[Step 5] Async redeem still works");
        vm.prank(user);
        uint256 reqId = gateway.requestRedeem(remainingShares);
        assertGt(reqId, 0, "async redeem should still work");

        _step("[Step 6] Admin re-enables sync redeem");
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(false);
        assertFalse(gateway.syncRedeemDisabled(), "should be re-enabled");

        _logPass();
    }

    function test_SetSyncRedeemDisabled_OnlyAdmin() public {
        _logCase("test_SetSyncRedeemDisabled_OnlyAdmin", unicode"非 admin 不能修改 `syncRedeemDisabled`");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        gateway.setSyncRedeemDisabled(true);
        _step("  nonAdmin reverted");

        _logPass();
    }

    // =======================================================================
    // 2. setSanctionsOracle: 更换制裁预言机
    // =======================================================================

    function test_SetSanctionsOracle_Success() public {
        _logCase("test_SetSanctionsOracle_Success", unicode"admin 更换制裁预言机地址，新预言机立即生效");

        MockSanctionsOracle_GAC newOracle = new MockSanctionsOracle_GAC();

        _step("[Step 1] Admin sets new oracle");
        vm.prank(admin);
        gateway.setSanctionsOracle(address(newOracle));
        assertEq(address(gateway.sanctionsOracle()), address(newOracle), "oracle updated");

        _step("[Step 2] New oracle is used for sanctions check");
        newOracle.updateSanctionStatus(user, true);
        assertTrue(gateway.isSanctioned(user), "new oracle effective");

        _logPass();
    }

    function test_SetSanctionsOracle_RejectsZeroAddress() public {
        _logCase("test_SetSanctionsOracle_RejectsZeroAddress", unicode"`setSanctionsOracle` 拒绝零地址");

        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        gateway.setSanctionsOracle(address(0));

        _logPass();
    }

    function test_SetSanctionsOracle_OnlyAdmin() public {
        _logCase("test_SetSanctionsOracle_OnlyAdmin", unicode"非 admin 不能更换制裁预言机");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        gateway.setSanctionsOracle(address(1));

        _logPass();
    }

    // =======================================================================
    // 3. setSanctionSafe: 更换制裁安全地址
    // =======================================================================

    function test_SetSanctionSafe_Success() public {
        _logCase("test_SetSanctionSafe_Success", unicode"admin 更换制裁安全地址");

        address newSafe = makeAddr("newSafe");

        vm.prank(admin);
        gateway.setSanctionSafe(newSafe);
        assertEq(gateway.sanctionSafe(), newSafe, "sanctionSafe updated");

        _logPass();
    }

    function test_SetSanctionSafe_RejectsZeroAddress() public {
        _logCase("test_SetSanctionSafe_RejectsZeroAddress", unicode"`setSanctionSafe` 拒绝零地址");

        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        gateway.setSanctionSafe(address(0));

        _logPass();
    }

    // =======================================================================
    // 4. setWhitelistEnabled: 白名单开关
    // =======================================================================

    function test_SetWhitelistEnabled_Toggle() public {
        _logCase("test_SetWhitelistEnabled_Toggle", unicode"admin 开启白名单后，未白名单用户被拒绝，白名单用户正常操作");

        _step("[Step 1] User deposits normally (whitelist off)");
        vm.prank(user);
        gateway.deposit(1000e6);

        _step("[Step 2] Admin enables whitelist");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        assertTrue(gateway.whitelistEnabled(), "whitelist enabled");

        _step("[Step 3] Non-whitelisted user can't deposit");
        address nonWl = makeAddr("nonWhitelisted");
        usdc.mint(nonWl, 1000e6);
        vm.prank(nonWl);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(nonWl);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, nonWl));
        gateway.deposit(500e6);
        _step("  non-whitelisted deposit reverted");

        _step("[Step 4] Whitelisted user can deposit");
        oracle.updateWhitelistStatus(user, true);
        vm.prank(user);
        gateway.deposit(500e6);
        _step("  whitelisted user deposit succeeded");

        _step("[Step 5] Admin disables whitelist");
        vm.prank(admin);
        gateway.setWhitelistEnabled(false);
        assertFalse(gateway.whitelistEnabled(), "whitelist disabled");

        _step("[Step 6] Previously rejected user can now deposit");
        vm.prank(nonWl);
        gateway.deposit(500e6);
        _step("  non-whitelisted user deposit succeeded after whitelist disabled");

        _logPass();
    }

    function test_SetWhitelistEnabled_OnlyAdmin() public {
        _logCase("test_SetWhitelistEnabled_OnlyAdmin", unicode"非 admin 不能修改 `whitelistEnabled`");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        gateway.setWhitelistEnabled(true);

        _logPass();
    }
}
