// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeAndInitVaultAndAdapter} from "../../script/UpgradeAndInitVaultAndAdapter.s.sol";
import {EmptyImplementation} from "../../src/EmptyImplementation.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {AccountantFactory} from "../../src/accountant/AccountantFactory.sol";
import {SubRedManagementAdapterFactory} from "../../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {MockSubRedManagement} from "../../src/mocks/strategy/MockSubRedManagement.sol";
import {MockERC20Mintable} from "../../src/mocks/token/MockERC20Mintable.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../../src/protocol/StrategyControllerFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract UpgradeAndInitVaultAndAdapterHarness is UpgradeAndInitVaultAndAdapter {
    function requireNonZeroForTest(address value, string memory envName) external pure {
        _requireNonZero(value, envName);
    }
}

contract ExistingFactoriesActivationFlowTest is Test {
    address internal constant BROADCAST_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function test_PhaseBInitializesRemainingDependentProxies() public {
        address admin = BROADCAST_SENDER;
        address bot = makeAddr("bot");
        address pauser = makeAddr("pauser");
        address capManager = makeAddr("capManager");
        address treasury = makeAddr("treasury");
        MockERC20Mintable stable = new MockERC20Mintable("Stable Coin", "STABLE", 6);
        MockERC20Mintable stToken = new MockERC20Mintable("DigiFt ST", "dST", 18);
        MockSubRedManagement subRed = new MockSubRedManagement(address(this));

        EmptyImplementation empty = new EmptyImplementation();
        VaultFactory vaultFactory = new VaultFactory(address(empty), admin);
        SubRedManagementAdapterFactory adapterFactory = new SubRedManagementAdapterFactory(address(empty), admin);
        address vaultProxy = vaultFactory.deployVault();
        address adapterProxy = adapterFactory.deployAdapter();

        SanctionsOracle oracleImpl = new SanctionsOracle();
        SanctionsOracleFactory oracleFactory = new SanctionsOracleFactory(address(oracleImpl), admin);
        address oracle = oracleFactory.deployAndInitOracle(admin, bot);

        AccountantFactory accountantFactory = new AccountantFactory(address(new Accountant()), admin);
        address accountantProxy = accountantFactory.deployAccountant();

        AccountantExecutor accountantExecutorImpl = new AccountantExecutor();
        address accountantExecutor = address(
            new ERC1967Proxy(address(accountantExecutorImpl), abi.encodeCall(AccountantExecutor.initialize, (admin)))
        );

        OperatorExecutor operatorExecutorImpl = new OperatorExecutor();
        address operatorExecutor = address(
            new ERC1967Proxy(address(operatorExecutorImpl), abi.encodeCall(OperatorExecutor.initialize, (admin, bot)))
        );

        StrategyControllerFactory controllerFactory =
            new StrategyControllerFactory(address(new StrategyController()), admin);
        address controllerProxy = controllerFactory.deployController();

        GatewayFactory gatewayFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        address gateway = gatewayFactory.deployAndInitGateway(
            IMantleVaultGateway.InitParams({
                vault: vaultProxy,
                sanctionsOracle: ISanctionsOracle(oracle),
                sanctionSafe: treasury,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        _setUpgradeEnv(
            address(vaultFactory),
            address(adapterFactory),
            vaultProxy,
            adapterProxy,
            admin,
            address(stable),
            gateway,
            controllerProxy,
            accountantProxy,
            accountantExecutor,
            operatorExecutor,
            treasury,
            pauser,
            capManager,
            address(subRed),
            address(stToken)
        );

        UpgradeAndInitVaultAndAdapter script = new UpgradeAndInitVaultAndAdapter();
        script.run();

        MantleYieldVault vault = MantleYieldVault(vaultProxy);
        Accountant accountant = Accountant(accountantProxy);
        StrategyController controller = StrategyController(controllerProxy);
        SubRedManagementAdapter adapter = SubRedManagementAdapter(adapterProxy);

        assertEq(vault.gateway(), gateway);
        assertEq(vault.controller(), controllerProxy);
        assertEq(vault.accountant(), accountantProxy);
        assertEq(vault.depositDailyRemaining(), 123_456e6);
        assertEq(vault.redeemDailyRemaining(), 789_012e18);
        assertEq(address(accountant.vault()), vaultProxy);
        assertTrue(accountant.hasRole(accountant.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(accountant.hasRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), accountantExecutor));
        assertEq(address(controller.vault()), vaultProxy);
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(controller.hasRole(controller.OPERATOR_EXECUTOR_ROLE(), operatorExecutor));
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), pauser));
        assertTrue(vault.hasRole(vault.CAP_MANAGER_ROLE(), capManager));
        assertEq(adapter.vault(), vaultProxy);
        assertEq(adapter.maxManualPriceDeviationBps(), 1000);

        vm.prank(accountantExecutor);
        adapter.setManualPosTokenPrice(1e18);
        vm.expectRevert();
        vm.prank(accountantExecutor);
        adapter.setManualPosTokenPrice(2e18);
    }

    function test_RequireNonZeroReportsEnvName() public {
        UpgradeAndInitVaultAndAdapterHarness script = new UpgradeAndInitVaultAndAdapterHarness();
        vm.expectRevert(bytes("UPGRADE_INIT_GATEWAY_ZERO"));
        script.requireNonZeroForTest(address(0), "UPGRADE_INIT_GATEWAY");
    }

    function _setUpgradeEnv(
        address vaultFactory,
        address adapterFactory,
        address vaultProxy,
        address adapterProxy,
        address admin,
        address stable,
        address gateway,
        address controller,
        address accountant,
        address accountantExecutor,
        address operatorExecutor,
        address treasury,
        address pauser,
        address capManager,
        address subRed,
        address stToken
    ) internal {
        vm.setEnv("UPGRADE_INIT_VAULT_FACTORY", vm.toString(vaultFactory));
        vm.setEnv("UPGRADE_INIT_SUBRED_ADAPTER_FACTORY", vm.toString(adapterFactory));
        vm.setEnv("UPGRADE_INIT_VAULT_PROXY", vm.toString(vaultProxy));
        vm.setEnv("UPGRADE_INIT_ADAPTER_PROXY", vm.toString(adapterProxy));
        vm.setEnv("UPGRADE_INIT_ADMIN", vm.toString(admin));
        vm.setEnv("UPGRADE_INIT_STABLE", vm.toString(stable));
        vm.setEnv("UPGRADE_INIT_GATEWAY", vm.toString(gateway));
        vm.setEnv("UPGRADE_INIT_CONTROLLER", vm.toString(controller));
        vm.setEnv("UPGRADE_INIT_ACCOUNTANT", vm.toString(accountant));
        vm.setEnv("UPGRADE_INIT_ACCOUNTANT_EXECUTOR", vm.toString(accountantExecutor));
        vm.setEnv("UPGRADE_INIT_OPERATOR_EXECUTOR", vm.toString(operatorExecutor));
        vm.setEnv("UPGRADE_INIT_TREASURY", vm.toString(treasury));
        vm.setEnv("UPGRADE_INIT_PAUSER", vm.toString(pauser));
        vm.setEnv("UPGRADE_INIT_CAP_MANAGER", vm.toString(capManager));
        vm.setEnv("UPGRADE_INIT_VAULT_NAME", "Mantle RWA Vault");
        vm.setEnv("UPGRADE_INIT_VAULT_SYMBOL", "mRWA");
        vm.setEnv("UPGRADE_INIT_MAX_REDEMPTION_FEE_BPS", "500");
        vm.setEnv("UPGRADE_INIT_REDEMPTION_FEE_BPS", "10");
        vm.setEnv("UPGRADE_INIT_MIN_REDEEM_AMOUNT", "1000000");
        vm.setEnv("UPGRADE_INIT_MIN_DEPOSIT_AMOUNT", "1000000");
        vm.setEnv("UPGRADE_INIT_DEPOSIT_DAILY_REMAINING", "123456000000");
        vm.setEnv("UPGRADE_INIT_REDEEM_DAILY_REMAINING", "789012000000000000000000");
        vm.setEnv("UPGRADE_INIT_ADAPTER_SUBRED_MANAGEMENT", vm.toString(subRed));
        vm.setEnv("UPGRADE_INIT_ADAPTER_ST_TOKEN", vm.toString(stToken));
        vm.setEnv("UPGRADE_INIT_ADAPTER_ADMIN", vm.toString(admin));
        vm.setEnv("UPGRADE_INIT_ADAPTER_CONTROLLER", vm.toString(controller));
        vm.setEnv("UPGRADE_INIT_ADAPTER_ACCOUNTANT", vm.toString(accountantExecutor));
        vm.setEnv("UPGRADE_INIT_ADAPTER_PRICE_ORACLE", vm.toString(address(0)));
        vm.setEnv("UPGRADE_INIT_ADAPTER_MANUAL_POS_TOKEN_PRICE", "0");
        vm.setEnv("UPGRADE_INIT_ADAPTER_SUBSCRIBE_STEP_ASSET", "0");
        vm.setEnv("UPGRADE_INIT_ADAPTER_REDEEM_STEP_POS", "0");
        vm.setEnv("UPGRADE_INIT_ADAPTER_MIN_SUBSCRIBE_ASSET", "0");
        vm.setEnv("UPGRADE_INIT_ADAPTER_MIN_REDEEM_POS", "0");
        vm.setEnv("UPGRADE_INIT_SETTLE_MS", "0");
        vm.setEnv("F_INITIAL_RATE", "1000000000000000000");
        vm.setEnv("F_MANAGEMENT_FEE_BPS", "50");
        vm.setEnv("F_MAX_ALLOWED_DEVIATION_BPS", "100");
        vm.setEnv("F_MIN_UPDATE_INTERVAL_SECONDS", "72000");
        vm.setEnv("F_MAX_COMPUTE_AGE_SECONDS", "300");
        vm.setEnv("F_BUFFER_TARGET_BPS", "1");
        vm.setEnv("F_REBALANCE_THRESHOLD_BPS", "10");
        vm.setEnv("F_REBALANCE_COOLDOWN", "3600");
        // Pin F_SENDER to admin so the script's preflight check passes regardless
        // of any F_SENDER leaked from the shell / .env / deploy-config.
        vm.setEnv("F_SENDER", vm.toString(admin));
    }
}
