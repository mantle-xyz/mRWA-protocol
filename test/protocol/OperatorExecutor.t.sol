// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract MockStrategyController is IStrategyControllerExecutor {
    error NotExecutorGateway();

    address public executorGateway;
    uint256 public rebalanceCount;
    bytes32 public lastProcessHash;
    bytes32 public lastAllocateHash;
    bytes32 public lastSettleHash;
    bytes32 public lastSettleBatchHash;

    modifier onlyExecutorGateway() {
        if (msg.sender != executorGateway) {
            revert NotExecutorGateway();
        }
        _;
    }

    function setExecutorGateway(address gateway) external {
        executorGateway = gateway;
    }

    function rebalance() external override onlyExecutorGateway {
        rebalanceCount++;
    }

    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalAsset)
        external
        override
        onlyExecutorGateway
    {
        lastProcessHash = keccak256(abi.encode(ids, batchTotalAsset));
    }

    function finalizeRedeemBatch(uint256[] calldata ids) external override onlyExecutorGateway {
        lastAllocateHash = keccak256(abi.encode(ids));
    }

    function settleAdapter(
        address adapter,
        uint256 posAmount,
        uint256 assetAmount,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds
    ) external override onlyExecutorGateway {
        lastSettleHash = keccak256(abi.encode(adapter, posAmount, assetAmount, investInFlightIds, redeemInFlightIds));
    }

    function settleAdapters(
        address[] calldata adapters,
        uint256[] calldata posAmounts,
        uint256[] calldata assetAmounts,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds
    ) external override onlyExecutorGateway {
        lastSettleBatchHash =
            keccak256(abi.encode(adapters, posAmounts, assetAmounts, investInFlightIds, redeemInFlightIds));
    }
}

contract OperatorExecutorTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant COMMAND_TYPEHASH =
        keccak256("Command(uint8 action,bytes32 dataHash,uint256 nonce,uint64 deadline)");

    MockStrategyController internal controller;
    OperatorExecutor internal executor;

    uint256 internal signerPk;
    address internal signer;
    address internal admin = makeAddr("admin");

    function setUp() public {
        controller = new MockStrategyController();
        signerPk = 0xA11CE;
        signer = vm.addr(signerPk);
        OperatorExecutor implementation = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (address(controller), admin, signer));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(implementation), initData)));
        controller.setExecutorGateway(address(executor));
    }

    function test_ControllerRejectsDirectCall_NotFromExecutorGateway() public {
        vm.expectRevert(MockStrategyController.NotExecutorGateway.selector);
        controller.rebalance();
    }

    function test_ExecuteRebalance_Success() public {
        OperatorExecutor.Command memory cmd =
            OperatorExecutor.Command({action: 0, data: "", nonce: 0, deadline: uint64(block.timestamp + 1 hours)});

        bytes memory sig = _sign(cmd, signerPk);
        executor.execute(cmd, sig);

        assertEq(controller.rebalanceCount(), 1);
        assertEq(executor.nonces(signer), 1);
    }

    function test_ExecuteProcessBatch_Routes() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 3;

        OperatorExecutor.Command memory cmd = OperatorExecutor.Command({
            action: 1,
            data: abi.encode(ids, uint256(500)),
            nonce: 0,
            deadline: uint64(block.timestamp + 1 hours)
        });

        bytes memory sig = _sign(cmd, signerPk);
        executor.execute(cmd, sig);

        assertEq(controller.lastProcessHash(), keccak256(abi.encode(ids, uint256(500))));
    }

    function test_ExecuteAllocateBatch_Routes() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9;

        OperatorExecutor.Command memory cmd = OperatorExecutor.Command({
            action: 2,
            data: abi.encode(ids),
            nonce: 0,
            deadline: uint64(block.timestamp + 1 hours)
        });

        bytes memory sig = _sign(cmd, signerPk);
        executor.execute(cmd, sig);

        assertEq(controller.lastAllocateHash(), keccak256(abi.encode(ids)));
    }

    function test_ExecuteSettleAdapter_Routes() public {
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = 7;
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = 9;

        OperatorExecutor.Command memory cmd = OperatorExecutor.Command({
            action: 3,
            data: abi.encode(address(0xBEEF), uint256(11), uint256(22), investInFlightIds, redeemInFlightIds),
            nonce: 0,
            deadline: uint64(block.timestamp + 1 hours)
        });

        bytes memory sig = _sign(cmd, signerPk);
        executor.execute(cmd, sig);

        assertEq(
            controller.lastSettleHash(),
            keccak256(abi.encode(address(0xBEEF), uint256(11), uint256(22), investInFlightIds, redeemInFlightIds))
        );
    }

    function test_ExecuteSettleAdapters_Routes() public {
        address[] memory adapters = new address[](2);
        adapters[0] = address(0xA1);
        adapters[1] = address(0xB2);
        uint256[] memory posAmounts = new uint256[](2);
        posAmounts[0] = 11;
        posAmounts[1] = 22;
        uint256[] memory assetAmounts = new uint256[](2);
        assetAmounts[0] = 33;
        assetAmounts[1] = 44;
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = 7;
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = 9;

        OperatorExecutor.Command memory cmd = OperatorExecutor.Command({
            action: 4,
            data: abi.encode(adapters, posAmounts, assetAmounts, investInFlightIds, redeemInFlightIds),
            nonce: 0,
            deadline: uint64(block.timestamp + 1 hours)
        });

        bytes memory sig = _sign(cmd, signerPk);
        executor.execute(cmd, sig);

        assertEq(
            controller.lastSettleBatchHash(),
            keccak256(abi.encode(adapters, posAmounts, assetAmounts, investInFlightIds, redeemInFlightIds))
        );
    }

    function test_RevertWhen_ReplayNonce() public {
        OperatorExecutor.Command memory cmd =
            OperatorExecutor.Command({action: 0, data: "", nonce: 0, deadline: uint64(block.timestamp + 1 hours)});
        bytes memory sig = _sign(cmd, signerPk);

        executor.execute(cmd, sig);

        vm.expectRevert();
        executor.execute(cmd, sig);
    }

    function test_RevertWhen_ExpiredDeadline() public {
        vm.warp(100);
        OperatorExecutor.Command memory cmd =
            OperatorExecutor.Command({action: 0, data: "", nonce: 0, deadline: uint64(block.timestamp - 1)});
        bytes memory sig = _sign(cmd, signerPk);

        vm.expectRevert(
            abi.encodeWithSelector(OperatorExecutor.DeadlineExpired.selector, cmd.deadline, block.timestamp)
        );
        executor.execute(cmd, sig);
    }

    function test_RevertWhen_InvalidSigner() public {
        OperatorExecutor.Command memory cmd =
            OperatorExecutor.Command({action: 0, data: "", nonce: 0, deadline: uint64(block.timestamp + 1 hours)});
        bytes memory sig = _sign(cmd, 0xB0B);

        vm.expectRevert(OperatorExecutor.InvalidSignature.selector);
        executor.execute(cmd, sig);
    }

    function test_SignerRole_NewSignerCanExecute_AfterGrant() public {
        uint256 newSignerPk = 0xBEEF;
        address newSigner = vm.addr(newSignerPk);

        vm.prank(admin);
        executor.setSigner(newSigner, true);

        OperatorExecutor.Command memory cmd =
            OperatorExecutor.Command({action: 0, data: "", nonce: 0, deadline: uint64(block.timestamp + 1 hours)});
        bytes memory sig = _sign(cmd, newSignerPk);
        executor.execute(cmd, sig);

        assertEq(controller.rebalanceCount(), 1);
        assertEq(executor.nonces(newSigner), 1);
    }

    function test_SignerRole_RevokedSignerCannotExecute() public {
        vm.prank(admin);
        executor.setSigner(signer, false);

        OperatorExecutor.Command memory cmd =
            OperatorExecutor.Command({action: 0, data: "", nonce: 0, deadline: uint64(block.timestamp + 1 hours)});
        bytes memory sig = _sign(cmd, signerPk);

        vm.expectRevert(OperatorExecutor.InvalidSignature.selector);
        executor.execute(cmd, sig);
    }

    function test_RevertWhen_SetSignerByNonAdmin() public {
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert();
        executor.setSigner(makeAddr("hsm"), true);
    }

    function _sign(OperatorExecutor.Command memory cmd, uint256 pk) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(COMMAND_TYPEHASH, cmd.action, keccak256(cmd.data), cmd.nonce, cmd.deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("OperatorExecutor")),
                keccak256(bytes("1")),
                block.chainid,
                address(executor)
            )
        );
    }
}
