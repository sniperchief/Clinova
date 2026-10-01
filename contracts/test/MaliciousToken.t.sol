// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ClinovaBase} from "./ClinovaBase.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {IClinovaEscrow} from "../src/interfaces/IClinovaEscrow.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {
    MockUSDC,
    FalseReturnToken,
    HookToken,
    ITokenReceiverHook,
    NoReturnToken,
    RevertingToken,
    LyingToken,
    BlacklistToken
} from "./mocks/Mocks.sol";

/// @notice A party (buyer or provider) that is a contract and runs one armed call from inside a token hook.
/// @dev Reverts from the hooked call are bubbled up, so a blocked re-entry fails the outer transaction with the
///      inner reason.
contract HookActor is ITokenReceiverHook {
    address public target;
    bytes public data;
    bool public armed;
    uint256 public hookCalls;

    function arm(address t, bytes calldata d) external {
        (target, data, armed) = (t, d, true);
    }

    function exec(address t, bytes calldata d) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = t.call(d);
        if (!ok) _bubble(ret);
    }

    function batch(address[] calldata ts, bytes[] calldata ds) external {
        for (uint256 i = 0; i < ts.length; ++i) {
            (bool ok, bytes memory ret) = ts[i].call(ds[i]);
            if (!ok) _bubble(ret);
        }
    }

    function onTokenTransfer() external {
        hookCalls++;
        if (!armed) return;
        armed = false;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) _bubble(ret);
    }

    function _bubble(bytes memory ret) internal pure {
        assembly {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}

/// @notice Phase 5 §11-13: reentrancy, non-standard/malicious ERC-20 behaviour and direct token transfers,
///         exercised through the whole five-contract system rather than one module at a time.
contract MaliciousTokenTest is ClinovaBase {
    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _redeploy(address token) internal {
        usdc = MockUSDC(token);
        _deploySystem(token);
        _eligible(alice);
        _eligible(bob);
        _fundBuyer(buyer, 10_000e6);
    }

    function _hookActorProvider(HookToken token) internal returns (HookActor p) {
        p = new HookActor();
        token.mint(address(p), MIN_STAKE);
        p.exec(address(token), abi.encodeCall(IERC20.approve, (address(registry), type(uint256).max)));
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CBC;
        p.exec(address(registry), abi.encodeCall(registry.register, (keccak256("meta-hook"), REGION, caps, MIN_STAKE)));
        vm.prank(verifier);
        registry.verifyProvider(address(p));
        p.exec(address(registry), abi.encodeCall(registry.activate, ()));
    }

    function _hookActorBuyer(HookToken token, uint256 amount) internal returns (HookActor b) {
        b = new HookActor();
        token.mint(address(b), amount);
        b.exec(address(token), abi.encodeCall(IERC20.approve, (address(market), type(uint256).max)));
    }

    function _createCall() internal view returns (bytes memory) {
        (uint64 a, uint64 s) = _deadlines();
        return abi.encodeCall(market.createRequest, (address(0), CBC, REGION, PRICE, a, s));
    }

    // ------------------------------------------------------------------
    // §11 Reentrancy (hook token)
    // ------------------------------------------------------------------

    /// A provider paid by escrow re-enters withdraw() from the token hook: blocked, credit paid exactly once.
    function test_Reentrancy_ProviderCannotWithdrawTwice() public {
        HookToken token = new HookToken();
        _redeploy(address(token));
        HookActor p = _hookActorProvider(token);
        uint256 id = _open();
        p.exec(address(market), abi.encodeCall(market.acceptRequest, (id)));
        p.exec(address(market), abi.encodeCall(market.startService, (id)));
        p.exec(address(market), abi.encodeCall(market.submitProof, (id, _proof(id))));
        vm.prank(buyer);
        market.confirmCompletion(id);

        token.setHooked(address(p), true);
        p.arm(address(escrow), abi.encodeWithSignature("withdraw()"));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        p.exec(address(escrow), abi.encodeWithSignature("withdraw()"));
        assertEq(escrow.credit(address(p)), PRICE, "credit untouched after the blocked attempt");

        // The revert also rolled back the hook's own disarm, so turn the hook off explicitly: one clean withdrawal.
        token.setHooked(address(p), false);
        p.exec(address(escrow), abi.encodeWithSignature("withdraw()"));
        assertEq(token.balanceOf(address(p)), PRICE);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        p.exec(address(escrow), abi.encodeWithSignature("withdraw()"));
        _assertEscrowExact(0);
    }

    /// During its own stake withdrawal, a provider re-enters the marketplace to accept a new job. The stake is already
    /// zeroed and the provider deactivated, so the registry rejects it: stake cannot back a job after leaving.
    function test_Reentrancy_StakeWithdrawHookCannotAcceptJob() public {
        HookToken token = new HookToken();
        _redeploy(address(token));
        HookActor p = _hookActorProvider(token);
        p.exec(address(registry), abi.encodeCall(registry.requestUnstake, ()));
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        uint256 id = _open();
        token.setHooked(address(p), true);
        p.arm(address(market), abi.encodeCall(market.acceptRequest, (id)));
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, address(p), CBC));
        p.exec(address(registry), abi.encodeCall(registry.withdrawStake, ()));
        assertEq(registry.getProvider(address(p)).stake, MIN_STAKE);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.OPEN));
    }

    /// Mid-funding (tokens not yet locked), the buyer's hook asks an accomplice provider to accept the half-created
    /// request. The escrow refuses to bind a payee to an unfunded deposit, so the whole creation reverts.
    function test_Reentrancy_AccomplicesCannotAcceptHalfFundedRequest() public {
        HookToken token = new HookToken();
        _redeploy(address(token));
        HookActor accomplice = _hookActorProvider(token);
        HookActor b = _hookActorBuyer(token, 1_000e6);
        uint256 nextId = market.nextRequestId();
        token.setHooked(address(b), true);
        b.arm(
            address(accomplice),
            abi.encodeCall(HookActor.exec, (address(market), abi.encodeCall(market.acceptRequest, (nextId))))
        );
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, nextId, ClinovaTypes.EscrowState.NONE)
        );
        b.exec(address(market), _createCall());
        assertEq(market.nextRequestId(), nextId, "nothing was created");
        assertEq(registry.getProvider(address(accomplice)).activeJobs, 0);
        _assertEscrowExact(0);
    }

    /// Mid-funding, the buyer tries to cancel the half-created request to get a refund credited before paying.
    function test_Reentrancy_BuyerCannotCancelHalfFundedRequest() public {
        HookToken token = new HookToken();
        _redeploy(address(token));
        HookActor b = _hookActorBuyer(token, 1_000e6);
        uint256 nextId = market.nextRequestId();
        token.setHooked(address(b), true);
        b.arm(address(market), abi.encodeCall(market.cancelRequest, (nextId)));
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, nextId, ClinovaTypes.EscrowState.NONE)
        );
        b.exec(address(market), _createCall());
        assertEq(escrow.credit(address(b)), 0);
    }

    /// Effects-first deposit: the provider's hook runs before its tokens move and uses the just-recorded stake to
    /// accept a job. This is safe only because the transaction is atomic; the test proves the end state is backed.
    function test_Reentrancy_DepositHookIsAtomicAndBacked() public {
        HookToken token = new HookToken();
        _redeploy(address(token));
        HookActor p = new HookActor();
        token.mint(address(p), MIN_STAKE * 2);
        p.exec(address(token), abi.encodeCall(IERC20.approve, (address(registry), type(uint256).max)));
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CBC;
        p.exec(address(registry), abi.encodeCall(registry.register, (keccak256("meta-hook"), REGION, caps, MIN_STAKE)));
        vm.prank(verifier);
        registry.verifyProvider(address(p));
        // minStake doubles: the provider cannot activate until it tops up.
        vm.prank(admin);
        registry.setMinStake(MIN_STAKE * 2);
        uint256 id = _open();

        // The hook fires on the provider (token sender) BEFORE its tokens move, after the stake was recorded.
        address[] memory ts = new address[](2);
        bytes[] memory ds = new bytes[](2);
        (ts[0], ds[0]) = (address(registry), abi.encodeCall(registry.activate, ()));
        (ts[1], ds[1]) = (address(market), abi.encodeCall(market.acceptRequest, (id)));
        token.setHooked(address(p), true);
        p.arm(address(p), abi.encodeCall(HookActor.batch, (ts, ds)));
        p.exec(address(registry), abi.encodeCall(registry.depositStake, (MIN_STAKE)));

        assertEq(p.hookCalls(), 1);
        assertEq(registry.getProvider(address(p)).activeJobs, 1, "accepted from inside the deposit");
        assertEq(registry.getProvider(address(p)).stake, MIN_STAKE * 2);
        // Atomicity: the stake that made it eligible did arrive in the same transaction.
        assertEq(token.balanceOf(address(registry)), registry.totalStaked(), "stake fully backed");
    }

    // ------------------------------------------------------------------
    // §12 False-return, reverting, no-return and lying tokens
    // ------------------------------------------------------------------

    /// transferFrom returning false never creates a request or a stake (SafeERC20 reverts the whole call).
    function test_FalseReturn_NoSilentAccountingOnInflows() public {
        FalseReturnToken token = new FalseReturnToken();
        _redeploy(address(token));
        uint256 nextId = market.nextRequestId();
        uint256 staked = registry.totalStaked();
        token.setFail(true);

        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);

        token.mint(carol, MIN_STAKE);
        vm.startPrank(carol);
        token.approve(address(registry), MIN_STAKE);
        bytes32[] memory caps = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        registry.register(keccak256("m"), REGION, caps, MIN_STAKE);
        vm.stopPrank();

        assertEq(market.nextRequestId(), nextId);
        assertEq(registry.totalStaked(), staked);
        assertEq(escrow.totalLocked(), 0);
    }

    /// transfer returning false on payout: withdraw reverts and the credit is kept; stake withdraw likewise.
    function test_FalseReturn_NoSilentAccountingOnOutflows() public {
        FalseReturnToken token = new FalseReturnToken();
        _redeploy(address(token));
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);

        token.setFail(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        escrow.withdraw();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        registry.withdrawStake();
        assertEq(escrow.credit(alice), PRICE);
        assertEq(registry.getProvider(alice).stake, MIN_STAKE);

        token.setFail(false);
        vm.startPrank(alice);
        escrow.withdraw();
        registry.withdrawStake();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), PRICE + MIN_STAKE);
        _assertEscrowExact(0);
    }

    /// While every transfer reverts (issuer outage), no state transition is blocked: lifecycle steps never move
    /// tokens. Credits accumulate and are withdrawable once the token works again.
    function test_RevertingToken_LifecycleContinuesWithdrawalsWait() public {
        RevertingToken token = new RevertingToken();
        _redeploy(address(token));
        uint256 open = _open();
        uint256 comp = _completed(alice);
        uint256 comp2 = _completed(bob);
        uint256 disp = _disputedFromCompleted(alice);

        token.setBroken(true);
        vm.prank(buyer);
        market.cancelRequest(open);
        vm.prank(buyer);
        market.confirmCompletion(comp);
        vm.prank(verifier);
        market.resolveDispute(disp, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        market.closeUnreviewed(comp2);

        // Inflows fail closed.
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(RevertingToken.TokenBroken.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        // Outflows wait.
        vm.prank(buyer);
        vm.expectRevert(RevertingToken.TokenBroken.selector);
        escrow.withdraw();
        assertEq(escrow.credit(buyer), 3 * PRICE);
        assertEq(escrow.credit(alice), PRICE);

        token.setBroken(false);
        vm.prank(buyer);
        escrow.withdraw();
        vm.prank(alice);
        escrow.withdraw();
        assertEq(escrow.totalLocked() + escrow.totalCredited(), 0);
        _assertEscrowExact(0);
    }

    /// A token with no return value (USDT style) works end to end through SafeERC20.
    function test_NoReturnToken_FullFlowThroughSafeERC20() public {
        NoReturnToken token = new NoReturnToken();
        _redeploy(address(token));
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.approveProof(id);
        vm.prank(alice);
        escrow.withdraw();
        assertEq(token.balanceOf(alice), PRICE);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(token.balanceOf(alice), PRICE + MIN_STAKE);
    }

    /// A token that claims success but moves nothing is caught on every inflow by the balance-delta checks.
    /// On outflows the protocol cannot detect it (documented: Clinova assumes a correct token, i.e. USDC).
    function test_LyingToken_InflowsFailClosed_OutflowsDocumented() public {
        LyingToken token = new LyingToken();
        _redeploy(address(token));
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);

        token.setLying(true);
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.TransferAmountMismatch.selector, PRICE, 0));
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.TransferAmountMismatch.selector, 50e6, 0));
        registry.depositStake(50e6);

        // Outflow: the credit is consumed but nothing arrives; the tokens stay as unaccounted surplus.
        vm.prank(alice);
        escrow.withdraw();
        assertEq(token.balanceOf(alice), 0);
        assertEq(escrow.surplus(), PRICE);
        assertEq(escrow.totalCredited(), 0);
    }

    // ------------------------------------------------------------------
    // USDC-style blacklist and pause (Circle controls)
    // ------------------------------------------------------------------

    /// A blacklisted provider is still paid (pull payment) and can withdraw to another address it controls.
    /// A blacklisted buyer's refund likewise. Nobody else is affected.
    function test_Blacklist_PartiesUseWithdrawTo() public {
        BlacklistToken token = new BlacklistToken();
        _redeploy(address(token));
        uint256 paid = _completed(alice);
        uint256 refunded = _open();
        token.blacklist(alice, true);
        token.blacklist(buyer, true);

        vm.prank(verifier);
        market.approveProof(paid); // settlement is not blocked by the payee's blacklist
        vm.prank(buyer);
        market.cancelRequest(refunded);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlacklistToken.Blacklisted.selector, alice));
        escrow.withdraw();
        address aliceCold = makeAddr("alice-cold");
        address buyerCold = makeAddr("buyer-cold");
        vm.prank(alice);
        escrow.withdrawTo(aliceCold);
        vm.prank(buyer);
        escrow.withdrawTo(buyerCold);
        assertEq(token.balanceOf(aliceCold), PRICE);
        assertEq(token.balanceOf(buyerCold), PRICE);
        _assertEscrowExact(0);
    }

    /// If the issuer blacklists the escrow itself, transitions still complete and credits are preserved; nothing
    /// can be withdrawn until the issuer lifts it. This is an external trust assumption (documented), not a lock
    /// the protocol can resolve.
    function test_Blacklist_EscrowItselfFreezesWithdrawalsOnly() public {
        BlacklistToken token = new BlacklistToken();
        _redeploy(address(token));
        uint256 id = _completed(alice);
        token.blacklist(address(escrow), true);
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlacklistToken.Blacklisted.selector, address(escrow)));
        escrow.withdraw();
        assertEq(escrow.credit(alice), PRICE);
        token.blacklist(address(escrow), false);
        vm.prank(alice);
        escrow.withdraw();
        assertEq(token.balanceOf(alice), PRICE);
    }

    function test_TokenPaused_TransitionsContinue() public {
        BlacklistToken token = new BlacklistToken();
        _redeploy(address(token));
        uint256 id = _completed(alice);
        token.setPaused(true);
        vm.prank(verifier);
        market.approveProof(id);
        vm.prank(alice);
        vm.expectRevert(BlacklistToken.TokenPaused.selector);
        escrow.withdraw();
        token.setPaused(false);
        vm.prank(alice);
        escrow.withdraw();
        assertEq(token.balanceOf(alice), PRICE);
    }

    // ------------------------------------------------------------------
    // §13 Direct token transfers
    // ------------------------------------------------------------------

    /// Tokens sent straight to the escrow become `surplus`: never credited, never withdrawable, never usable to
    /// back a request, and they do not disturb accounting.
    function test_DirectTransfer_ToEscrowIsInertSurplus() public {
        uint256 id = _open();
        usdc.mint(attacker, 500e6);
        vm.prank(attacker);
        usdc.transfer(address(escrow), 500e6);
        _assertEscrowExact(500e6);

        // Cannot be withdrawn by the sender or anyone else.
        vm.prank(attacker);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        // Cannot back a request: funding still pulls the full price from the buyer.
        address poor = makeAddr("poor-buyer");
        vm.prank(poor);
        usdc.approve(address(market), type(uint256).max);
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(poor);
        vm.expectRevert(); // ERC20InsufficientBalance
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        // Existing obligations unaffected.
        vm.prank(buyer);
        market.cancelRequest(id);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(escrow.totalLocked() + escrow.totalCredited(), 0);
        _assertEscrowExact(500e6);
    }

    /// Tokens sent straight to the registry are not stake: totalStaked and every provider's stake are unchanged,
    /// and withdrawStake returns exactly the recorded stake.
    function test_DirectTransfer_ToRegistryIsNotStake() public {
        uint256 staked = registry.totalStaked();
        usdc.mint(attacker, 77e6);
        vm.prank(attacker);
        usdc.transfer(address(registry), 77e6);
        assertEq(registry.totalStaked(), staked);
        assertEq(usdc.balanceOf(address(registry)), staked + 77e6);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(usdc.balanceOf(alice), MIN_STAKE);
        assertEq(usdc.balanceOf(address(registry)), registry.totalStaked() + 77e6);
    }

    /// Tokens sent to the marketplace, ProofOfService or ReputationRegistry are stranded (no function moves them),
    /// and the marketplace never uses its own balance for funding.
    function test_DirectTransfer_ToNonCustodyModulesIsStranded() public {
        usdc.mint(attacker, 30e6);
        vm.startPrank(attacker);
        usdc.transfer(address(market), 10e6);
        usdc.transfer(address(pos), 10e6);
        usdc.transfer(address(rep), 10e6);
        vm.stopPrank();
        uint256 id = _open(); // funded from the buyer, not from the marketplace's stray balance
        assertEq(usdc.balanceOf(address(market)), 10e6);
        assertEq(escrow.getDeposit(id).amount, PRICE);
        _assertEscrowExact(0);
    }

    // ------------------------------------------------------------------
    // P5-1 regression: withdrawTo(escrow) silently burned the caller's credit into surplus
    // ------------------------------------------------------------------

    function test_WithdrawTo_RejectsEscrowAndMarketplaceAsRecipient() public {
        uint256 id = _open();
        vm.prank(buyer);
        market.cancelRequest(id);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.InvalidRecipient.selector, address(escrow)));
        escrow.withdrawTo(address(escrow));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.InvalidRecipient.selector, address(market)));
        escrow.withdrawTo(address(market));

        assertEq(escrow.credit(buyer), PRICE, "credit kept");
        _assertEscrowExact(0);
    }
}
