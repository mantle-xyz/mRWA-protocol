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

    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalAsset) external override onlyExecutorGateway {
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
        lastSettleBatchHash = keccak256(
            abi.encode(adapters, posAmounts, assetAmounts, investInFlightIds, redeemInFlightIds)
        );
    }
}

contract OperatorExecutorTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant REBALANCE_TYPEHASH =
        keccak256("Rebalance(address controller,uint256 nonce,uint64 deadline)");
    bytes32 internal constant PROCESS_REDEEM_BATCH_TYPEHASH = keccak256(
        "ProcessRedeemBatch(address controller,bytes32 idsHash,uint256 batchTotalAsset,uint256 nonce,uint64 deadline)"
    );
    bytes32 internal constant FINALIZE_REDEEM_BATCH_TYPEHASH =
        keccak256("FinalizeRedeemBatch(address controller,bytes32 idsHash,uint256 nonce,uint64 deadline)");
    bytes32 internal constant SETTLE_ADAPTER_TYPEHASH = keccak256(
        "SettleAdapter(address controller,address adapter,uint256 posAmount,uint256 assetAmount,bytes32 investInFlightIdsHash,bytes32 redeemInFlightIdsHash,uint256 nonce,uint64 deadline)"
    );
    bytes32 internal constant SETTLE_ADAPTERS_TYPEHASH = keccak256(
        "SettleAdapters(address controller,bytes32 adaptersHash,bytes32 posAmountsHash,bytes32 assetAmountsHash,bytes32 investInFlightIdsHash,bytes32 redeemInFlightIdsHash,uint256 nonce,uint64 deadline)"
    );

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
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, signer));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(implementation), initData)));
        controller.setExecutorGateway(address(executor));
    }

    function test_ControllerRejectsDirectCall_NotFromExecutorGateway() public {
        vm.expectRevert(MockStrategyController.NotExecutorGateway.selector);
        controller.rebalance();
    }

    function test_ExecuteRebalance_Success() public {
        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signRebalance(address(controller), nonce, deadline, signerPk);

        executor.executeRebalance(address(controller), nonce, deadline, sig);

        assertEq(controller.rebalanceCount(), 1);
        assertEq(executor.nonces(signer), 1);
    }

    function test_ExecuteProcessBatch_Routes() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 3;

        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signProcessRedeemBatch(address(controller), ids, 500, nonce, deadline, signerPk);

        executor.executeProcessRedeemBatch(address(controller), ids, 500, nonce, deadline, sig);

        assertEq(controller.lastProcessHash(), keccak256(abi.encode(ids, uint256(500))));
    }

    function test_ExecuteAllocateBatch_Routes() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9;

        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signFinalizeRedeemBatch(address(controller), ids, nonce, deadline, signerPk);

        executor.executeFinalizeRedeemBatch(address(controller), ids, nonce, deadline, sig);

        assertEq(controller.lastAllocateHash(), keccak256(abi.encode(ids)));
    }

    function test_ExecuteSettleAdapter_Routes() public {
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = 7;
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = 9;

        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signSettleAdapter(
            address(controller),
            address(0xBEEF),
            11,
            22,
            investInFlightIds,
            redeemInFlightIds,
            nonce,
            deadline,
            signerPk
        );

        executor.executeSettleAdapter(
            address(controller), address(0xBEEF), 11, 22, investInFlightIds, redeemInFlightIds, nonce, deadline, sig
        );

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

        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signSettleAdapters(
            address(controller),
            adapters,
            posAmounts,
            assetAmounts,
            investInFlightIds,
            redeemInFlightIds,
            nonce,
            deadline,
            signerPk
        );

        executor.executeSettleAdapters(
            address(controller),
            adapters,
            posAmounts,
            assetAmounts,
            investInFlightIds,
            redeemInFlightIds,
            nonce,
            deadline,
            sig
        );

        assertEq(
            controller.lastSettleBatchHash(),
            keccak256(abi.encode(adapters, posAmounts, assetAmounts, investInFlightIds, redeemInFlightIds))
        );
    }

    function test_RevertWhen_ReplayNonce() public {
        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signRebalance(address(controller), nonce, deadline, signerPk);

        executor.executeRebalance(address(controller), nonce, deadline, sig);

        vm.expectRevert();
        executor.executeRebalance(address(controller), nonce, deadline, sig);
    }

    function test_RevertWhen_ExpiredDeadline() public {
        vm.warp(100);
        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp - 1);
        bytes memory sig = _signRebalance(address(controller), nonce, deadline, signerPk);

        vm.expectRevert(abi.encodeWithSelector(OperatorExecutor.DeadlineExpired.selector, deadline, block.timestamp));
        executor.executeRebalance(address(controller), nonce, deadline, sig);
    }

    function test_RevertWhen_InvalidSigner() public {
        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signRebalance(address(controller), nonce, deadline, 0xB0B);

        vm.expectRevert(OperatorExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(controller), nonce, deadline, sig);
    }

    function test_SignerRole_NewSignerCanExecute_AfterGrant() public {
        uint256 newSignerPk = 0xBEEF;
        address newSigner = vm.addr(newSignerPk);

        vm.prank(admin);
        executor.setSigner(newSigner, true);

        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signRebalance(address(controller), nonce, deadline, newSignerPk);
        executor.executeRebalance(address(controller), nonce, deadline, sig);

        assertEq(controller.rebalanceCount(), 1);
        assertEq(executor.nonces(newSigner), 1);
    }

    function test_SignerRole_RevokedSignerCannotExecute() public {
        vm.prank(admin);
        executor.setSigner(signer, false);

        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signRebalance(address(controller), nonce, deadline, signerPk);

        vm.expectRevert(OperatorExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(controller), nonce, deadline, sig);
    }

    function test_RevertWhen_SetSignerByNonAdmin() public {
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert();
        executor.setSigner(makeAddr("hsm"), true);
    }

    function test_RevertWhen_ZeroController() public {
        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signRebalance(address(0), nonce, deadline, signerPk);

        vm.expectRevert(OperatorExecutor.InvalidAddress.selector);
        executor.executeRebalance(address(0), nonce, deadline, sig);
    }

    function test_RevertWhen_ControllerIsEOA() public {
        address eoaController = makeAddr("eoaController");
        uint256 nonce = 0;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signRebalance(eoaController, nonce, deadline, signerPk);

        vm.expectRevert(abi.encodeWithSelector(OperatorExecutor.InvalidController.selector, eoaController));
        executor.executeRebalance(eoaController, nonce, deadline, sig);
    }

    function _signRebalance(address controller_, uint256 nonce, uint64 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(REBALANCE_TYPEHASH, controller_, nonce, deadline));
        return _signTypedData(structHash, pk);
    }

    function _signProcessRedeemBatch(
        address controller_,
        uint256[] memory ids,
        uint256 batchTotalAsset,
        uint256 nonce,
        uint64 deadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                PROCESS_REDEEM_BATCH_TYPEHASH,
                controller_,
                keccak256(abi.encodePacked(ids)),
                batchTotalAsset,
                nonce,
                deadline
            )
        );
        return _signTypedData(structHash, pk);
    }

    function _signFinalizeRedeemBatch(
        address controller_,
        uint256[] memory ids,
        uint256 nonce,
        uint64 deadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(FINALIZE_REDEEM_BATCH_TYPEHASH, controller_, keccak256(abi.encodePacked(ids)), nonce, deadline)
        );
        return _signTypedData(structHash, pk);
    }

    function _signSettleAdapter(
        address controller_,
        address adapter,
        uint256 posAmount,
        uint256 assetAmount,
        uint256[] memory investInFlightIds,
        uint256[] memory redeemInFlightIds,
        uint256 nonce,
        uint64 deadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLE_ADAPTER_TYPEHASH,
                controller_,
                adapter,
                posAmount,
                assetAmount,
                keccak256(abi.encodePacked(investInFlightIds)),
                keccak256(abi.encodePacked(redeemInFlightIds)),
                nonce,
                deadline
            )
        );
        return _signTypedData(structHash, pk);
    }

    function _signSettleAdapters(
        address controller_,
        address[] memory adapters,
        uint256[] memory posAmounts,
        uint256[] memory assetAmounts,
        uint256[] memory investInFlightIds,
        uint256[] memory redeemInFlightIds,
        uint256 nonce,
        uint64 deadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLE_ADAPTERS_TYPEHASH,
                controller_,
                keccak256(abi.encodePacked(adapters)),
                keccak256(abi.encodePacked(posAmounts)),
                keccak256(abi.encodePacked(assetAmounts)),
                keccak256(abi.encodePacked(investInFlightIds)),
                keccak256(abi.encodePacked(redeemInFlightIds)),
                nonce,
                deadline
            )
        );
        return _signTypedData(structHash, pk);
    }

    function _signTypedData(bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
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
