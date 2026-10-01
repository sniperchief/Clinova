// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ClinovaEscrow} from "../src/ClinovaEscrow.sol";
import {IClinovaEscrow} from "../src/interfaces/IClinovaEscrow.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {MockUSDC, Mock18Decimals, FalseReturnToken, HookToken, ITokenReceiverHook} from "./mocks/Mocks.sol";

/// @notice Withdraws from the escrow and tries to re-enter from a token hook.
contract ReentrantWithdrawer is ITokenReceiverHook {
    ClinovaEscrow public immutable escrow;
    uint8 public mode; // 0 none, 1 re-withdraw, 2 re-release

    constructor(ClinovaEscrow e) {
        escrow = e;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function withdraw() external {
        escrow.withdraw();
    }

    function onTokenTransfer() external {
        uint8 m = mode;
        mode = 0;
        if (m == 1) escrow.withdraw();
        else if (m == 2) escrow.release(1);
    }
}

/// @notice Escrow in isolation: this test contract plays the (immutable) marketplace.
contract ClinovaEscrowTest is Test {
    MockUSDC internal usdc;
    ClinovaEscrow internal escrow;

    address internal payer = makeAddr("payer");
    address internal payer2 = makeAddr("payer2");
    address internal payee = makeAddr("payee");
    address internal payee2 = makeAddr("payee2");
    address internal attacker = makeAddr("attacker");
    uint256 internal constant AMT = 25e6;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new ClinovaEscrow(IERC20(address(usdc)), address(this));
    }

    /// @dev Mimics the marketplace: tokens arrive first, then lock.
    function _deposit(uint256 id, address from, uint256 amount) internal {
        usdc.mint(address(escrow), amount);
        escrow.lock(id, from, amount);
    }

    function _funded(uint256 id) internal {
        _deposit(id, payer, AMT);
        escrow.assignPayee(id, payee);
    }

    function _assertExact(uint256 donations) internal view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalLocked() + escrow.totalCredited() + donations);
    }

    // --- construction ---

    function test_Constructor() public view {
        assertEq(address(escrow.usdc()), address(usdc));
        assertEq(escrow.marketplace(), address(this));
    }

    function test_Constructor_Reverts() public {
        vm.expectRevert(IClinovaEscrow.ZeroAddress.selector);
        new ClinovaEscrow(IERC20(address(0)), address(this));
    }

    function test_Constructor_RevertsOnZeroMarketplace() public {
        vm.expectRevert(IClinovaEscrow.ZeroAddress.selector);
        new ClinovaEscrow(IERC20(address(usdc)), address(0));
    }

    function test_Constructor_RevertsOnWrongDecimals() public {
        Mock18Decimals bad = new Mock18Decimals();
        vm.expectRevert(IClinovaEscrow.InvalidToken.selector);
        new ClinovaEscrow(IERC20(address(bad)), address(this));
    }

    // --- lock ---

    function test_Lock() public {
        usdc.mint(address(escrow), AMT);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IClinovaEscrow.FundsLocked(1, payer, AMT);
        escrow.lock(1, payer, AMT);
        ClinovaTypes.Deposit memory d = escrow.getDeposit(1);
        assertEq(d.payer, payer);
        assertEq(d.amount, AMT);
        assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.FUNDED));
        assertEq(d.payee, address(0));
        assertEq(escrow.totalLocked(), AMT);
        _assertExact(0);
    }

    function test_Lock_RevertsWithoutTokens() public {
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.DepositNotReceived.selector, AMT, 0));
        escrow.lock(1, payer, AMT);
    }

    function test_Lock_RevertsWhenOnlyPartialTokens() public {
        usdc.mint(address(escrow), AMT - 1);
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.DepositNotReceived.selector, AMT, AMT - 1));
        escrow.lock(1, payer, AMT);
    }

    function test_Lock_CannotReuseAnotherRequestsFunds() public {
        _deposit(1, payer, AMT);
        // No new tokens arrived: request 2 cannot be backed by request 1's deposit.
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.DepositNotReceived.selector, AMT, 0));
        escrow.lock(2, payer2, AMT);
    }

    function test_Lock_CannotReuseCreditedFunds() public {
        _funded(1);
        escrow.refund(1); // AMT now credited to payer, still held
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.DepositNotReceived.selector, AMT, 0));
        escrow.lock(2, payer2, AMT);
    }

    function test_Lock_RevertsDoubleFunding() public {
        _deposit(1, payer, AMT);
        usdc.mint(address(escrow), AMT);
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, 1, ClinovaTypes.EscrowState.FUNDED)
        );
        escrow.lock(1, payer, AMT);
    }

    function test_Lock_RevertsAfterTerminal() public {
        _funded(1);
        escrow.release(1);
        usdc.mint(address(escrow), AMT);
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, 1, ClinovaTypes.EscrowState.RELEASED)
        );
        escrow.lock(1, payer, AMT);
    }

    function test_Lock_RevertsZeroInputs() public {
        usdc.mint(address(escrow), AMT);
        vm.expectRevert(IClinovaEscrow.ZeroAmount.selector);
        escrow.lock(1, payer, 0);
        vm.expectRevert(IClinovaEscrow.ZeroAddress.selector);
        escrow.lock(1, address(0), AMT);
    }

    function test_Lock_RevertsUint128Overflow() public {
        uint256 big = uint256(type(uint128).max) + 1;
        usdc.mint(address(escrow), big);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, big));
        escrow.lock(1, payer, big);
    }

    function test_Lock_DonationBecomesSurplusNotCredit() public {
        usdc.mint(address(escrow), 7e6); // direct transfer, nobody's obligation
        assertEq(escrow.surplus(), 7e6);
        _funded(1);
        escrow.release(1);
        assertEq(escrow.credit(payee), AMT);
        _assertExact(7e6);
    }

    // --- authorization ---

    function test_OnlyMarketplace() public {
        _funded(1);
        vm.startPrank(attacker);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.lock(2, attacker, AMT);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.assignPayee(1, attacker);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.release(1);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.refund(1);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        vm.stopPrank();
        assertEq(usdc.balanceOf(attacker), 0);
    }

    // --- payee binding ---

    function test_AssignPayee_OnlyOnce() public {
        _deposit(1, payer, AMT);
        vm.expectEmit(true, true, false, false, address(escrow));
        emit IClinovaEscrow.PayeeAssigned(1, payee);
        escrow.assignPayee(1, payee);
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.PayeeAlreadyAssigned.selector, 1));
        escrow.assignPayee(1, payee2);
        assertEq(escrow.getDeposit(1).payee, payee);
    }

    function test_AssignPayee_RevertsInvalid() public {
        _deposit(1, payer, AMT);
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.InvalidPayee.selector, address(0)));
        escrow.assignPayee(1, address(0));
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.InvalidPayee.selector, payer));
        escrow.assignPayee(1, payer);
    }

    function test_AssignPayee_RevertsUnfunded() public {
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, 1, ClinovaTypes.EscrowState.NONE)
        );
        escrow.assignPayee(1, payee);
    }

    // --- release / refund ---

    function test_Release_CreditsBoundPayeeOnly() public {
        _funded(1);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IClinovaEscrow.FundsReleased(1, payee, AMT);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IClinovaEscrow.PaymentCredited(payee, 1, AMT);
        assertEq(escrow.release(1), AMT);
        assertEq(escrow.credit(payee), AMT);
        assertEq(escrow.credit(payer), 0);
        assertEq(escrow.totalLocked(), 0);
        assertEq(escrow.totalCredited(), AMT);
        assertEq(uint8(escrow.getDeposit(1).state), uint8(ClinovaTypes.EscrowState.RELEASED));
        _assertExact(0);
    }

    function test_Release_RevertsWithoutPayee() public {
        _deposit(1, payer, AMT);
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.PayeeNotAssigned.selector, 1));
        escrow.release(1);
    }

    function test_Release_RevertsUnfunded() public {
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, 7, ClinovaTypes.EscrowState.NONE)
        );
        escrow.release(7);
    }

    function test_Refund_CreditsPayerOnly() public {
        _funded(1);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IClinovaEscrow.RefundCredited(payer, 1, AMT);
        assertEq(escrow.refund(1), AMT);
        assertEq(escrow.credit(payer), AMT);
        assertEq(escrow.credit(payee), 0);
        assertEq(uint8(escrow.getDeposit(1).state), uint8(ClinovaTypes.EscrowState.REFUNDED));
        _assertExact(0);
    }

    function test_Refund_WorksWithoutPayee() public {
        _deposit(1, payer, AMT);
        escrow.refund(1);
        assertEq(escrow.credit(payer), AMT);
    }

    function test_NoDoubleSettlementOrRefund() public {
        _funded(1);
        escrow.release(1);
        bytes memory released =
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, 1, ClinovaTypes.EscrowState.RELEASED);
        vm.expectRevert(released);
        escrow.release(1);
        vm.expectRevert(released);
        escrow.refund(1);

        _funded(2);
        escrow.refund(2);
        bytes memory refunded =
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, 2, ClinovaTypes.EscrowState.REFUNDED);
        vm.expectRevert(refunded);
        escrow.refund(2);
        vm.expectRevert(refunded);
        escrow.release(2);
        vm.expectRevert(refunded);
        escrow.assignPayee(2, payee2);

        assertEq(escrow.credit(payee), AMT);
        assertEq(escrow.credit(payer), AMT);
        _assertExact(0);
    }

    function test_RequestsAreIsolated() public {
        _funded(1);
        _deposit(2, payer2, 40e6);
        escrow.assignPayee(2, payee2);
        escrow.release(1);
        assertEq(escrow.getDeposit(2).amount, 40e6);
        assertEq(uint8(escrow.getDeposit(2).state), uint8(ClinovaTypes.EscrowState.FUNDED));
        escrow.refund(2);
        assertEq(escrow.credit(payee), AMT);
        assertEq(escrow.credit(payer2), 40e6);
        assertEq(escrow.credit(payee2), 0);
    }

    // --- withdrawals ---

    function test_Withdraw() public {
        _funded(1);
        escrow.release(1);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IClinovaEscrow.Withdrawal(payee, payee, AMT);
        vm.prank(payee);
        assertEq(escrow.withdraw(), AMT);
        assertEq(usdc.balanceOf(payee), AMT);
        assertEq(escrow.credit(payee), 0);
        assertEq(escrow.totalCredited(), 0);
        _assertExact(0);
    }

    function test_Withdraw_AccumulatesAcrossRequests() public {
        _funded(1);
        _deposit(2, payer2, 10e6);
        escrow.assignPayee(2, payee);
        escrow.release(1);
        escrow.release(2);
        vm.prank(payee);
        escrow.withdraw();
        assertEq(usdc.balanceOf(payee), AMT + 10e6);
    }

    function test_Withdraw_RevertsZeroAndRepeated() public {
        vm.prank(payee);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        _funded(1);
        escrow.release(1);
        vm.startPrank(payee);
        escrow.withdraw();
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), AMT);
    }

    function test_Withdraw_CannotTakeOthersCredit() public {
        _funded(1);
        escrow.release(1);
        _funded(2);
        escrow.refund(2);
        vm.prank(attacker);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdrawTo(attacker);
        vm.prank(payer);
        escrow.withdraw();
        assertEq(usdc.balanceOf(payer), AMT, "payer gets only its refund");
        assertEq(escrow.credit(payee), AMT, "payee credit untouched");
    }

    function test_Withdraw_LockedFundsNotWithdrawable() public {
        _funded(1);
        vm.prank(payee);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        vm.prank(payer);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
    }

    function test_WithdrawTo() public {
        _funded(1);
        escrow.release(1);
        address alt = makeAddr("alt");
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IClinovaEscrow.Withdrawal(payee, alt, AMT);
        vm.prank(payee);
        escrow.withdrawTo(alt);
        assertEq(usdc.balanceOf(alt), AMT);
        vm.prank(payee);
        vm.expectRevert(IClinovaEscrow.ZeroAddress.selector);
        escrow.withdrawTo(address(0));
    }

    // --- malicious token behaviour ---

    function test_FalseReturnToken_WithdrawRevertsAndCreditKept() public {
        FalseReturnToken token = new FalseReturnToken();
        usdc = MockUSDC(address(token));
        escrow = new ClinovaEscrow(IERC20(address(token)), address(this));
        _funded(1);
        escrow.release(1);
        token.setFail(true);
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        escrow.withdraw();
        assertEq(escrow.credit(payee), AMT, "credit survives failed transfer");
        assertEq(escrow.totalCredited(), AMT);
        token.setFail(false);
        vm.prank(payee);
        escrow.withdraw();
        assertEq(token.balanceOf(payee), AMT);
    }

    function test_Reentrancy_WithdrawHookBlocked() public {
        HookToken token = new HookToken();
        usdc = MockUSDC(address(token));
        escrow = new ClinovaEscrow(IERC20(address(token)), address(this));
        ReentrantWithdrawer rw = new ReentrantWithdrawer(escrow);
        _deposit(1, payer, AMT);
        escrow.assignPayee(1, address(rw));
        escrow.release(1);
        token.setHooked(address(rw), true);

        rw.setMode(1);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rw.withdraw();
        assertEq(escrow.credit(address(rw)), AMT);

        rw.setMode(0);
        rw.withdraw();
        assertEq(token.balanceOf(address(rw)), AMT);
        _assertExact(0);
    }

    function test_Reentrancy_HookCannotReenterRelease() public {
        HookToken token = new HookToken();
        usdc = MockUSDC(address(token));
        // The withdrawer contract is the "marketplace" here, so only the guard (not auth) stops re-entry.
        ReentrantWithdrawer rw;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        escrow = new ClinovaEscrow(IERC20(address(token)), predicted);
        rw = new ReentrantWithdrawer(escrow);
        assertEq(address(rw), predicted);
        token.mint(address(escrow), 2 * AMT);
        vm.startPrank(address(rw));
        escrow.lock(1, payer, AMT);
        escrow.lock(2, payer2, AMT);
        escrow.assignPayee(2, address(rw));
        escrow.assignPayee(1, payee);
        escrow.release(2);
        vm.stopPrank();
        token.setHooked(address(rw), true);
        rw.setMode(2); // during its withdraw, try to release request 1
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rw.withdraw();
        assertEq(uint8(escrow.getDeposit(1).state), uint8(ClinovaTypes.EscrowState.FUNDED));
    }
}
