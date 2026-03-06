// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapterExecutor} from "../../interfaces/adapters/IAdapterExecutor.sol";
import {IStrategyAdapter} from "../../interfaces/adapters/IStrategyAdapter.sol";
import {AdapterCall} from "../../libs/AdapterCodec.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract BaseAdapter is IStrategyAdapter, IAdapterExecutor, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable USDC;
    address public immutable VAULT;
    bool public paused;

    mapping(bytes32 => bool) public usedSalt;

    event Paused(bool paused);
    event Execute(bytes32 indexed execId, uint8 action, bytes32 meta);

    error PausedError();
    error DeadlineExceeded();
    error SaltUsed(bytes32 salt);
    error NotController();
    error NotOperator();
    error Unsupported();

    modifier onlyController() {
        if (!hasRole(CONTROLLER_ROLE, msg.sender)) {
            revert NotController();
        }
        _;
    }

    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotOperator();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert PausedError();
        }
        _;
    }

    constructor(address usdc, address vault_, address admin, address controller, address operator) {
        USDC = IERC20(usdc);
        VAULT = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONTROLLER_ROLE, controller);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(PAUSER_ROLE, admin);
    }

    function asset() external view virtual override returns (address) {
        return address(USDC);
    }

    function vault() external view virtual override returns (address) {
        return VAULT;
    }

    function setPaused(bool p) external {
        require(hasRole(PAUSER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "NO_PAUSE_ROLE");
        paused = p;
        emit Paused(p);
    }

    function _checkCall(AdapterCall memory c) internal {
        if (c.deadline != 0 && block.timestamp > c.deadline) {
            revert DeadlineExceeded();
        }
        if (c.salt != bytes32(0)) {
            if (usedSalt[c.salt]) {
                revert SaltUsed(c.salt);
            }
            usedSalt[c.salt] = true;
        }
    }

    /// @notice Emergency sweep: transfer all of a token to receiver (admin only)
    function sweep(address token, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(receiver, bal);
    }
}
