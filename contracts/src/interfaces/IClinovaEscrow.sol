// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClinovaTypes} from "../libraries/ClinovaTypes.sol";

/// @title IClinovaEscrow
/// @notice USDC payment custody per request, with pull-payment balances.
/// @dev Per-request lifecycle: NONE -> FUNDED -> (RELEASED | REFUNDED).
///      lock/assignPayee/release/refund are callable only by the immutable marketplace address and are always
///      tied to one request id and its stored deposit. No function takes an arbitrary amount or recipient to pay.
///      There is no admin, no pause, and no token rescue.
interface IClinovaEscrow {
    event FundsLocked(uint256 indexed requestId, address indexed payer, uint256 amount);
    event PayeeAssigned(uint256 indexed requestId, address indexed payee);
    event FundsReleased(uint256 indexed requestId, address indexed payee, uint256 amount);
    event PaymentCredited(address indexed account, uint256 indexed requestId, uint256 amount);
    event RefundCredited(address indexed account, uint256 indexed requestId, uint256 amount);
    event Withdrawal(address indexed account, address indexed recipient, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidToken();
    error OnlyMarketplace();
    error InvalidEscrowState(uint256 requestId, ClinovaTypes.EscrowState current);
    error PayeeAlreadyAssigned(uint256 requestId);
    error PayeeNotAssigned(uint256 requestId);
    error InvalidPayee(address payee);
    error InvalidRecipient(address recipient);
    error DepositNotReceived(uint256 required, uint256 available);
    error NothingToWithdraw();

    // --- marketplace only, per request ---
    function lock(uint256 requestId, address payer, uint256 amount) external;
    function assignPayee(uint256 requestId, address payee) external;
    function release(uint256 requestId) external returns (uint256 amount);
    function refund(uint256 requestId) external returns (uint256 amount);

    // --- any account, own credit only ---
    function withdraw() external returns (uint256 amount);
    function withdrawTo(address recipient) external returns (uint256 amount);

    // --- views ---
    function usdc() external view returns (IERC20);
    function marketplace() external view returns (address);
    function getDeposit(uint256 requestId) external view returns (ClinovaTypes.Deposit memory);
    function credit(address account) external view returns (uint256);
    function totalLocked() external view returns (uint256);
    function totalCredited() external view returns (uint256);
    function surplus() external view returns (uint256);
}
