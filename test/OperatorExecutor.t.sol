// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyController} from "../src/interfaces/strategy/IStrategyController.sol";
import {OperatorExecutor} from "../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract MockStrategyController is IStrategyController {
    uint256 public rebalanceCount;
    bytes32 public lastProcessHash;
    bytes32 public lastAllocateHash;

    function rebalance() external override {
        rebalanceCount++;
    }

    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalAsset) external override {
        lastProcessHash = keccak256(abi.encode(ids, batchTotalAsset));
    }

    function allocateAssetsBatch(uint256[] calldata ids, uint256[] calldata inFlightIds) external override {
        lastAllocateHash = keccak256(abi.encode(ids, inFlightIds));
    }

    function claimAdapterAssets(address adapter, uint256 posAmount, uint256 assetAmount) external override {
        lastAllocateHash = keccak256(abi.encode(adapter, posAmount, assetAmount));
    }

    function setAdapterPaused(address, bool) external override {}

    function setAdaptersPaused(address[] calldata, bool) external override {}
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
        uint256[] memory inFlightIds = new uint256[](2);
        inFlightIds[0] = 11;
        inFlightIds[1] = 12;

        OperatorExecutor.Command memory cmd = OperatorExecutor.Command({
            action: 2,
            data: abi.encode(ids, inFlightIds),
            nonce: 0,
            deadline: uint64(block.timestamp + 1 hours)
        });

        bytes memory sig = _sign(cmd, signerPk);
        executor.execute(cmd, sig);

        assertEq(controller.lastAllocateHash(), keccak256(abi.encode(ids, inFlightIds)));
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
