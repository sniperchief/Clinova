// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ClinovaTypes} from "./libraries/ClinovaTypes.sol";
import {IClinovaEscrow} from "./interfaces/IClinovaEscrow.sol";

/// @title ClinovaEscrow
/// @notice Holds USDC for service requests. Settlement and refunds credit balances; recipients pull with withdraw().
/// @dev Accounting identity (I1): usdc.balanceOf(this) == totalLocked + totalCredited + surplus, surplus >= 0.
///      `surplus` is only ever tokens sent directly to this contract; it is never credited to anyone.
///      The escrow defends its own per-request state machine and does not rely on the marketplace status:
///        - lock only from NONE, and only if the tokens have actually arrived;
///        - payee is bound once and release pays only that payee;
///        - refund pays only the recorded payer;
///        - RELEASED and REFUNDED are terminal, so no request pays out twice.
contract ClinovaEscrow is IClinovaEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint8 public constant USDC_DECIMALS = 6;

    IERC20 public immutable usdc;
    /// @notice The only address allowed to lock/assign/release/refund. Fixed at deployment; not a role.
    address public immutable marketplace;

    uint256 public totalLocked;
    uint256 public totalCredited;

    mapping(uint256 requestId => ClinovaTypes.Deposit) private _deposits;
    mapping(address account => uint256) private _credit;

    modifier onlyMarketplace() {
        if (msg.sender != marketplace) revert OnlyMarketplace();
        _;
    }

    constructor(IERC20 usdc_, address marketplace_) {
        if (address(usdc_) == address(0) || marketplace_ == address(0)) revert ZeroAddress();
        if (IERC20Metadata(address(usdc_)).decimals() != USDC_DECIMALS) revert InvalidToken();
        usdc = usdc_;
        marketplace = marketplace_;
    }

    // ------------------------------------------------------------------
    // Marketplace (per request)
    // ------------------------------------------------------------------

    /// @notice Record `amount` for `requestId`. The tokens must already have been transferred to this contract:
    ///         the escrow checks its unaccounted balance rather than trusting `amount`.
    function lock(uint256 requestId, address payer, uint256 amount) external nonReentrant onlyMarketplace {
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        ClinovaTypes.Deposit storage d = _deposits[requestId];
        if (d.state != ClinovaTypes.EscrowState.NONE) revert InvalidEscrowState(requestId, d.state);
        uint256 available = surplus();
        if (available < amount) revert DepositNotReceived(amount, available);

        d.payer = payer;
        d.amount = amount.toUint128();
        d.state = ClinovaTypes.EscrowState.FUNDED;
        totalLocked += amount;
        emit FundsLocked(requestId, payer, amount);
    }

    /// @notice Bind the only address `release` can ever pay for this request. Callable once, while FUNDED.
    function assignPayee(uint256 requestId, address payee) external nonReentrant onlyMarketplace {
        ClinovaTypes.Deposit storage d = _requireFunded(requestId);
        if (d.payee != address(0)) revert PayeeAlreadyAssigned(requestId);
        if (payee == address(0) || payee == d.payer) revert InvalidPayee(payee);
        d.payee = payee;
        emit PayeeAssigned(requestId, payee);
    }

    /// @notice FUNDED -> RELEASED: credit the full deposit to the bound payee.
    function release(uint256 requestId) external nonReentrant onlyMarketplace returns (uint256 amount) {
        ClinovaTypes.Deposit storage d = _requireFunded(requestId);
        address payee = d.payee;
        if (payee == address(0)) revert PayeeNotAssigned(requestId);
        d.state = ClinovaTypes.EscrowState.RELEASED;
        amount = _moveToCredit(payee, d.amount);
        emit FundsReleased(requestId, payee, amount);
        emit PaymentCredited(payee, requestId, amount);
    }

    /// @notice FUNDED -> REFUNDED: credit the full deposit back to the payer.
    function refund(uint256 requestId) external nonReentrant onlyMarketplace returns (uint256 amount) {
        ClinovaTypes.Deposit storage d = _requireFunded(requestId);
        d.state = ClinovaTypes.EscrowState.REFUNDED;
        amount = _moveToCredit(d.payer, d.amount);
        emit RefundCredited(d.payer, requestId, amount);
    }

    // ------------------------------------------------------------------
    // Withdrawals (own credit only; never paused)
    // ------------------------------------------------------------------

    function withdraw() external returns (uint256) {
        return _withdraw(msg.sender);
    }

    /// @notice Withdraw own credit to another address (e.g. if the caller's address is blocked by the token issuer).
    /// @dev The escrow and the marketplace are rejected as recipients: tokens sent there could never be credited or
    ///      moved again, so the caller's credit would be silently and permanently lost (Phase 5, P5-1).
    function withdrawTo(address recipient) external returns (uint256) {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this) || recipient == marketplace) revert InvalidRecipient(recipient);
        return _withdraw(recipient);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getDeposit(uint256 requestId) external view returns (ClinovaTypes.Deposit memory) {
        return _deposits[requestId];
    }

    function credit(address account) external view returns (uint256) {
        return _credit[account];
    }

    /// @notice Tokens held beyond all obligations (direct transfers). Never credited to anyone.
    function surplus() public view returns (uint256) {
        return usdc.balanceOf(address(this)) - totalLocked - totalCredited;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _requireFunded(uint256 requestId) internal view returns (ClinovaTypes.Deposit storage d) {
        d = _deposits[requestId];
        if (d.state != ClinovaTypes.EscrowState.FUNDED) revert InvalidEscrowState(requestId, d.state);
    }

    function _moveToCredit(address account, uint256 amount) internal returns (uint256) {
        totalLocked -= amount;
        totalCredited += amount;
        _credit[account] += amount;
        return amount;
    }

    function _withdraw(address recipient) internal nonReentrant returns (uint256 amount) {
        amount = _credit[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _credit[msg.sender] = 0;
        totalCredited -= amount;
        emit Withdrawal(msg.sender, recipient, amount);
        usdc.safeTransfer(recipient, amount);
    }
}
