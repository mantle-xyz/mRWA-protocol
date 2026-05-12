// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
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
// QA Test: Vault Share Transfer & Compliance Scenarios
// ---------------------------------------------------------------------------

contract VaultShareTransferQATest is Test {
    MockUSDC6 internal usdc;
    SanctionsOracle internal sanctionsOracle;
    MockAccountant internal accountant;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;

    address internal adminAddr = makeAddr("admin");
    address internal complianceAddr = makeAddr("compliance");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafeAddr = makeAddr("sanctionSafe");

    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal nonGateway = makeAddr("nonGateway");

    uint256 internal constant DEPOSIT_AMOUNT = 10_000e6;
    uint256 internal constant TRANSFER_AMOUNT = 100e6;

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Vault 份额转账与合规场景";
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

    function _updateSanctionStatus(address account, bool status) internal {
        vm.prank(complianceAddr);
        sanctionsOracle.updateSanctionStatus(account, status);
    }

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    function setUp() public {
        usdc = new MockUSDC6();
        SanctionsOracle sanctionsOracleImpl = new SanctionsOracle();
        sanctionsOracle = SanctionsOracle(address(new ERC1967Proxy(
            address(sanctionsOracleImpl),
            abi.encodeCall(SanctionsOracle.initialize, (adminAddr, complianceAddr))
        )));
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
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
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

        // Give userA shares via gateway deposit
        usdc.mint(userA, DEPOSIT_AMOUNT);
        vm.startPrank(userA);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Give userB some shares too (for redeem tests)
        usdc.mint(userB, DEPOSIT_AMOUNT);
        vm.startPrank(userB);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // 1. test_NormalShareTransfer_SanctionsCheck
    // -----------------------------------------------------------------------

    function test_NormalShareTransfer_SanctionsCheck() public {
        _logCase(
            "test_NormalShareTransfer_SanctionsCheck",
            unicode"普通 share transfer 时通过 Gateway 执行 sanctions 校验"
        );

        _step("[Step 1] Verify userA and userB are not sanctioned and userA has sufficient shares");
        uint256 userABefore = vault.balanceOf(userA);
        uint256 userBBefore = vault.balanceOf(userB);
        _step(string.concat("  userA shares before: ", vm.toString(userABefore)));
        _step(string.concat("  userB shares before: ", vm.toString(userBBefore)));
        assertTrue(userABefore >= TRANSFER_AMOUNT, "userA must have enough shares");

        _step("[Step 2] userA calls vault.transfer(userB, 100e6)");
        vm.prank(userA);
        bool success = vault.transfer(userB, TRANSFER_AMOUNT);
        assertTrue(success, "transfer should succeed");
        _step("  PASS: Transfer succeeded");

        _step("[Step 3] Verify share balances changed correctly");
        uint256 userAAfter = vault.balanceOf(userA);
        uint256 userBAfter = vault.balanceOf(userB);
        assertEq(userAAfter, userABefore - TRANSFER_AMOUNT, "userA shares decreased");
        assertEq(userBAfter, userBBefore + TRANSFER_AMOUNT, "userB shares increased");
        _step(string.concat("  userA shares after: ", vm.toString(userAAfter)));
        _step(string.concat("  userB shares after: ", vm.toString(userBAfter)));
        _step("  PASS: Share balances updated correctly");

        _step("[Step 4] Sanction userB, then verify transfer reverts -- proves gateway sanctions oracle is consulted");
        _updateSanctionStatus(userB, true);
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, userB));
        vault.transfer(userB, TRANSFER_AMOUNT);
        _step("  PASS: Transfer reverted with Vault__Sanctioned(userB) after sanctions update");

        _step("[Step 5] Lift sanction on userB, verify transfer succeeds again");
        _updateSanctionStatus(userB, false);
        vm.prank(userA);
        bool success2 = vault.transfer(userB, TRANSFER_AMOUNT);
        assertTrue(success2, "transfer should succeed after lifting sanction");
        _step("  PASS: Transfer succeeds again after lifting sanction");
        _step("  CONCLUSION: vault.transfer() routes through Gateway sanctions oracle on every call");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_FromSanctioned_TransferRejected
    // -----------------------------------------------------------------------

    function test_FromSanctioned_TransferRejected() public {
        _logCase(
            "test_FromSanctioned_TransferRejected",
            unicode"from 被制裁时普通 share transfer 被拒绝"
        );

        _step("[Step 1] Sanction userA");
        _updateSanctionStatus(userA, true);

        _step("[Step 2] userA calls vault.transfer(userB, 100e6)");
        uint256 userABefore = vault.balanceOf(userA);
        uint256 userBBefore = vault.balanceOf(userB);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, userA));
        vault.transfer(userB, TRANSFER_AMOUNT);
        _step("  PASS: Transaction reverted with Vault__Sanctioned(userA)");

        _step("[Step 3] Verify share balances unchanged");
        assertEq(vault.balanceOf(userA), userABefore, "userA shares unchanged");
        assertEq(vault.balanceOf(userB), userBBefore, "userB shares unchanged");
        _step("  PASS: Both balances unchanged");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_ToSanctioned_TransferRejected
    // -----------------------------------------------------------------------

    function test_ToSanctioned_TransferRejected() public {
        _logCase(
            "test_ToSanctioned_TransferRejected",
            unicode"to 被制裁时普通 share transfer 被拒绝"
        );

        _step("[Step 1] Sanction userB");
        _updateSanctionStatus(userB, true);

        _step("[Step 2] userA calls vault.transfer(userB, 100e6)");
        uint256 userABefore = vault.balanceOf(userA);
        uint256 userBBefore = vault.balanceOf(userB);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, userB));
        vault.transfer(userB, TRANSFER_AMOUNT);
        _step("  PASS: Transaction reverted with Vault__Sanctioned(userB)");

        _step("[Step 3] Verify share balances unchanged");
        assertEq(vault.balanceOf(userA), userABefore, "userA shares unchanged");
        assertEq(vault.balanceOf(userB), userBBefore, "userB shares unchanged");
        _step("  PASS: Both balances unchanged");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_VaultPaused_TransferRejected
    // -----------------------------------------------------------------------

    function test_VaultPaused_TransferRejected() public {
        _logCase(
            "test_VaultPaused_TransferRejected",
            unicode"Vault pause 时普通 share transfer 被拒绝"
        );

        _step("[Step 1] Admin grants PAUSER_ROLE and pauses the vault");
        vm.startPrank(adminAddr);
        vault.grantRole(vault.PAUSER_ROLE(), adminAddr);
        vault.pause();
        vm.stopPrank();
        assertTrue(vault.paused(), "Vault should be paused");
        _step("  PASS: Vault is paused");

        _step("[Step 2] userA calls vault.transfer(userB, 100e6)");
        uint256 userABefore = vault.balanceOf(userA);
        uint256 userBBefore = vault.balanceOf(userB);

        vm.prank(userA);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.transfer(userB, TRANSFER_AMOUNT);
        _step("  PASS: Transaction reverted (EnforcedPause)");

        _step("[Step 3] Verify share balances unchanged");
        assertEq(vault.balanceOf(userA), userABefore, "userA shares unchanged");
        assertEq(vault.balanceOf(userB), userBBefore, "userB shares unchanged");
        _step("  PASS: Both balances unchanged");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_MintBurn_SkipSanctionsBranch
    // -----------------------------------------------------------------------

    function test_MintBurn_SkipSanctionsBranch() public {
        _logCase(
            "test_MintBurn_SkipSanctionsBranch",
            unicode"mint / burn 不进入普通 share transfer sanctions 分支"
        );

        _step("[Step 1] Deposit via gateway triggers mint (from=address(0))");
        address userC = makeAddr("userC");
        usdc.mint(userC, 1000e6);
        vm.startPrank(userC);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = gateway.deposit(1000e6);
        vm.stopPrank();
        assertTrue(shares > 0, "Mint should succeed");
        _step(string.concat("  PASS: Deposit minted ", vm.toString(shares), " shares"));

        _step("[Step 2] RequestRedeem via gateway triggers burn (to=address(0))");
        vm.prank(userC);
        uint256 requestId = gateway.requestRedeem(shares);
        _step(string.concat("  PASS: requestRedeem succeeded with requestId=", vm.toString(requestId)));
        assertEq(vault.balanceOf(userC), 0, "userC shares burned");
        _step("  PASS: userC shares are zero after burn");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_SanctionedOwner_RequestRedeem_SanctionSafeRoute
    // -----------------------------------------------------------------------

    function test_SanctionedOwner_RequestRedeem_SanctionSafeRoute() public {
        _logCase(
            "test_SanctionedOwner_RequestRedeem_SanctionSafeRoute",
            unicode"被制裁 owner 通过 Gateway `requestRedeem` 时触发 `sanctionSafe` 特例路由"
        );

        _step("[Step 1] Give sanctioned user shares, then sanction them");
        // userA already has shares from setUp; transfer some to a separate sanctioned user
        address sanctionedUser = makeAddr("sanctionedUser");
        vm.prank(userA);
        vault.transfer(sanctionedUser, 500e6);
        uint256 sanctionedShares = vault.balanceOf(sanctionedUser);
        _step(string.concat("  sanctionedUser shares: ", vm.toString(sanctionedShares)));

        _updateSanctionStatus(sanctionedUser, true);
        _step("  sanctionedUser is now sanctioned");

        _step("[Step 2] sanctionedUser calls gateway.requestRedeem(shares)");
        uint256 safeBefore = vault.balanceOf(sanctionSafeAddr);
        vm.prank(sanctionedUser);
        uint256 returnVal = gateway.requestRedeem(sanctionedShares);
        _step(string.concat("  gateway.requestRedeem returned: ", vm.toString(returnVal)));

        _step("[Step 3] Verify: returns 0, shares moved to sanctionSafe, no redemption request created");
        assertEq(returnVal, 0, "Should return 0 for sanctioned route");
        _step("  PASS: Gateway returned 0");

        assertEq(vault.balanceOf(sanctionedUser), 0, "sanctionedUser shares should be 0");
        _step("  PASS: sanctionedUser shares are 0");

        uint256 safeAfter = vault.balanceOf(sanctionSafeAddr);
        assertEq(safeAfter - safeBefore, sanctionedShares, "sanctionSafe received shares");
        _step(string.concat("  PASS: sanctionSafe received ", vm.toString(sanctionedShares), " shares"));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_SanctionSafeRoute_BypassesTransferSanctions
    // -----------------------------------------------------------------------

    function test_SanctionSafeRoute_BypassesTransferSanctions() public {
        _logCase(
            "test_SanctionSafeRoute_BypassesTransferSanctions",
            unicode"`sanctionSafe` 特例路由不走普通 transfer sanctions 拦截"
        );

        _step("[Step 1] Give sanctioned user shares and sanction them");
        address sanctionedUser = makeAddr("sanctionedUser2");
        vm.prank(userA);
        vault.transfer(sanctionedUser, 500e6);
        uint256 sanctionedShares = vault.balanceOf(sanctionedUser);
        _updateSanctionStatus(sanctionedUser, true);
        _step(string.concat("  sanctionedUser shares: ", vm.toString(sanctionedShares)));

        _step("[Step 2] sanctionedUser calls gateway.requestRedeem - triggers routeSanctionedShares");
        _step("  This routes via vault._update with msg.sender==gateway && to==sanctionSafe");
        _step("  which bypasses the enforceShareTransfer check");

        uint256 safeBefore = vault.balanceOf(sanctionSafeAddr);
        vm.prank(sanctionedUser);
        gateway.requestRedeem(sanctionedShares);

        uint256 safeAfter = vault.balanceOf(sanctionSafeAddr);
        assertEq(safeAfter - safeBefore, sanctionedShares, "Routing completed successfully");
        assertEq(vault.balanceOf(sanctionedUser), 0, "sanctionedUser shares depleted");
        _step("  PASS: routeSanctionedShares bypassed normal transfer sanctions check");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_NonGateway_RouteSanctionedShares_Rejected
    // -----------------------------------------------------------------------

    function test_NonGateway_RouteSanctionedShares_Rejected() public {
        _logCase(
            "test_NonGateway_RouteSanctionedShares_Rejected",
            unicode"非 Gateway 调用 `routeSanctionedShares` 被拒绝"
        );

        _step("[Step 1] Non-gateway address directly calls vault.routeSanctionedShares(...)");
        vm.prank(nonGateway);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.routeSanctionedShares(userA, 100e6);
        _step("  PASS: Transaction reverted with Vault__OnlyGateway");

        _logPass();
    }
}
