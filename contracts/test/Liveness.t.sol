// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ClinovaBase} from "./ClinovaBase.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";

/// @notice Phase 5 §7-10: liveness when actors disappear and while paused. The property throughout: every request
///         reaches a terminal state and every credit and stake can be withdrawn, without the admin and without any
///         verifier, and the provider is never paid merely because nobody answered.
contract LivenessTest is ClinovaBase {
    function _drainAndAssertClean(address[] memory accounts) internal {
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (escrow.credit(accounts[i]) > 0) {
                vm.prank(accounts[i]);
                escrow.withdraw();
            }
        }
        assertEq(escrow.totalLocked(), 0, "nothing locked");
        assertEq(escrow.totalCredited(), 0, "nothing owed");
        _assertEscrowExact(0);
    }

    function _parties() internal view returns (address[] memory a) {
        a = new address[](4);
        (a[0], a[1], a[2], a[3]) = (buyer, buyer2, alice, bob);
    }

    function _revokeAllMarketVerifiers() internal {
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(admin);
        market.revokeRole(role, verifier);
    }

    // ------------------------------------------------------------------
    // §7 No verifier
    // ------------------------------------------------------------------

    /// A deployment where no verifier role was ever granted: no provider can become eligible, so requests can only
    /// be cancelled or expire, and every token goes back.
    function test_ZeroVerifiers_FreshDeploymentNeverLocks() public {
        Deploy d = new Deploy();
        Deploy.Deployment memory dep = d.deploy(_config(address(usdc)), address(d));
        (registry, escrow, market, pos, rep) =
        (dep.registry, dep.escrow, dep.marketplace, dep.proofOfService, dep.reputation);
        _registerProvider(alice); // registered but can never be verified
        _fundBuyer(buyer, 1_000e6);
        uint256 a = _open();
        uint256 b = _open();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, CBC));
        market.acceptRequest(a);
        vm.prank(buyer);
        market.cancelRequest(a);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        market.expireRequest(b);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        vm.prank(alice);
        registry.withdrawStake();
        _drainAndAssertClean(_parties());
        assertEq(usdc.balanceOf(address(registry)), 0);
    }

    function test_VerifierRemovedAfterCreation_PendingProof_AndDuringDispute() public {
        uint256 openBefore = _open();
        uint256 comp = _completed(alice);
        uint256 dispNoProof = _accepted(bob);
        vm.prank(buyer);
        market.openDispute(dispNoProof, REASON);
        uint256 dispProof = _disputedFromCompleted(alice);
        _revokeAllMarketVerifiers();

        // Work that does not need a verifier continues.
        vm.prank(alice);
        market.acceptRequest(openBefore);
        vm.prank(alice);
        market.startService(openBefore);
        vm.prank(alice);
        market.submitProof(openBefore, _proof(openBefore));
        // Nobody reviews: everything exits by time, to the buyer, with no fault recorded.
        vm.warp(vm.getBlockTimestamp() + DISPUTE + 1);
        market.closeUnreviewed(comp);
        market.closeUnreviewed(openBefore);
        market.resolveDisputeByTimeout(dispNoProof);
        market.resolveDisputeByTimeout(dispProof);
        assertEq(escrow.credit(alice) + escrow.credit(bob), 0, "never paid without positive acceptance");
        assertEq(escrow.credit(buyer), 4 * PRICE);
        assertEq(rep.getReputation(alice).failedJobs + rep.getReputation(bob).failedJobs, 0, "no fault recorded");
        assertEq(_activeJobs(alice) + _activeJobs(bob), 0);
        _drainAndAssertClean(_parties());
    }

    /// Admin renounces (or loses) its key through the 2-step, delayed process: every exit still works.
    function test_AdminUnavailable_ProtocolStillTerminates() public {
        uint256 open = _open();
        uint256 acc = _accepted(alice);
        uint256 comp = _completed(bob);
        uint256 disp = _disputedFromCompleted(alice);
        vm.prank(pauser);
        market.pause();
        vm.startPrank(admin);
        market.beginDefaultAdminTransfer(address(0));
        registry.beginDefaultAdminTransfer(address(0));
        vm.warp(vm.getBlockTimestamp() + ADMIN_DELAY + 1);
        market.renounceRole(market.DEFAULT_ADMIN_ROLE(), admin);
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();
        assertEq(market.defaultAdmin(), address(0));
        assertEq(registry.defaultAdmin(), address(0));

        vm.warp(vm.getBlockTimestamp() + 60 days);
        market.expireRequest(open);
        vm.prank(alice);
        market.expireRequest(acc);
        market.closeUnreviewed(comp);
        market.resolveDisputeByTimeout(disp);
        _drainAndAssertClean(_parties());
        vm.startPrank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        registry.withdrawStake();
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), MIN_STAKE);
    }

    // ------------------------------------------------------------------
    // §8 Buyer disappears after the provider submits proof
    // ------------------------------------------------------------------

    function test_BuyerDisappears_NoVerifier_RefundNotPayment() public {
        uint256 id = _completed(alice); // buyer never acts again
        vm.warp(_req(id).reviewDeadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, _req(id).reviewDeadline));
        market.closeUnreviewed(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice); // the provider itself frees its obligation
        market.closeUnreviewed(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.REFUNDED));
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.UNRESOLVED));
        assertEq(escrow.credit(alice), 0, "Phase 4 rule: no payment for an unreviewed completion");
        assertEq(escrow.credit(buyer), PRICE, "held for the buyer indefinitely");
        assertEq(_activeJobs(alice), 0);
        ClinovaTypes.Reputation memory r = rep.getReputation(alice);
        assertEq(r.completedJobs, 1);
        assertEq(r.failedJobs, 0);
        // The provider's stake is free; the buyer's refund waits for the buyer (or its withdrawTo).
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        vm.prank(alice);
        registry.withdrawStake();
        vm.warp(vm.getBlockTimestamp() + 3650 days);
        vm.prank(buyer);
        escrow.withdraw();
        _assertEscrowExact(0);
    }

    function test_BuyerDisappears_VerifierApproves_ProviderPaid() public {
        uint256 id = _completed(alice);
        vm.warp(_req(id).reviewDeadline + 1); // even late, until someone closes it
        vm.prank(verifier);
        market.approveProof(id);
        assertEq(escrow.credit(alice), PRICE);
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.APPROVED));
    }

    // ------------------------------------------------------------------
    // §9 Provider disappears
    // ------------------------------------------------------------------

    function test_ProviderDisappears_NeverStarts() public {
        uint256 id = _accepted(alice);
        uint64 sd = _req(id).serviceDeadline;
        vm.warp(sd);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, sd));
        market.expireRequest(id); // not before the provider's own deadline
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(sd + 1);
        vm.prank(buyer);
        market.expireRequest(id);
        assertEq(escrow.credit(buyer), PRICE);
        assertEq(rep.getReputation(alice).failedJobs, 1);
        assertEq(_activeJobs(alice), 0);
    }

    function test_ProviderDisappears_StartedNeverCompletes_StakeHeldUntilExpiry() public {
        uint256 id = _inService(alice);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING); // unbonding over, but the job is still open
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ActiveObligation.selector, 1));
        registry.withdrawStake();
        vm.prank(buyer);
        market.expireRequest(id);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(escrow.credit(buyer), PRICE);
        assertEq(rep.getReputation(alice).failedJobs, 1);
    }

    /// Before the deadline the buyer cannot reclaim funds by expiry, but can dispute; with no verifier the dispute
    /// times out to a refund (no fault). With a verifier it can be resolved as provider fault.
    function test_ProviderDisappears_BeforeDeadline_BuyerDisputes() public {
        uint256 a = _accepted(alice);
        uint256 b = _accepted(alice);
        vm.startPrank(buyer);
        market.openDispute(a, REASON);
        market.openDispute(b, REASON);
        vm.stopPrank();
        vm.prank(verifier);
        market.resolveDispute(a, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        vm.warp(_req(b).disputeDeadline + 1);
        market.resolveDisputeByTimeout(b);
        assertEq(escrow.credit(buyer), 2 * PRICE);
        assertEq(rep.getReputation(alice).failedJobs, 1, "fault only where a verifier decided it");
        assertEq(rep.getReputation(alice).disputes, 2);
    }

    // ------------------------------------------------------------------
    // §10 Pause at every stage (both pausable contracts paused)
    // ------------------------------------------------------------------

    function _pauseAll() internal {
        vm.startPrank(pauser);
        market.pause();
        registry.pause();
        vm.stopPrank();
    }

    function test_Pause_BeforeCreation() public {
        _pauseAll();
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        bytes32[] memory caps = new bytes32[](0);
        vm.prank(attacker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.register(keccak256("m"), REGION, caps, MIN_STAKE);
        assertEq(usdc.balanceOf(address(escrow)), 0, "no new obligation was created");
    }

    function test_Pause_AfterFunding() public {
        uint256 a = _open();
        uint256 b = _open();
        _pauseAll();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.acceptRequest(a); // no new acceptance
        vm.prank(buyer);
        market.cancelRequest(a); // buyer still exits
        vm.warp(vm.getBlockTimestamp() + 2 days);
        market.expireRequest(b); // and anyone can expire
        vm.prank(buyer);
        escrow.withdraw();
        _assertEscrowExact(0);
    }

    function test_Pause_AfterAcceptance() public {
        uint256 a = _accepted(alice);
        uint256 b = _accepted(bob);
        uint256 c = _accepted(alice);
        _pauseAll();
        vm.startPrank(alice);
        market.startService(a);
        market.submitProof(a, _proof(a));
        vm.stopPrank();
        vm.prank(bob);
        market.openDispute(b, REASON);
        vm.warp(_req(c).serviceDeadline + 1);
        vm.prank(buyer);
        market.expireRequest(c);
        assertEq(uint8(_status(a)), uint8(ClinovaTypes.Status.COMPLETED));
        assertEq(uint8(_status(b)), uint8(ClinovaTypes.Status.DISPUTED));
        assertEq(uint8(_status(c)), uint8(ClinovaTypes.Status.EXPIRED));
    }

    function test_Pause_AfterProofSubmission() public {
        uint256 a = _completed(alice);
        uint256 b = _completed(alice);
        uint256 c = _completed(bob);
        uint256 d = _completed(bob);
        _pauseAll();
        vm.prank(buyer);
        market.confirmCompletion(a);
        vm.prank(verifier);
        market.approveProof(b);
        vm.prank(verifier);
        market.rejectProof(c, REASON);
        vm.warp(vm.getBlockTimestamp() + REVIEW + 1);
        market.closeUnreviewed(d);
        assertEq(escrow.credit(alice), 2 * PRICE);
        assertEq(escrow.credit(buyer), PRICE);
    }

    function test_Pause_DuringDispute() public {
        uint256 a = _disputedFromCompleted(alice);
        uint256 b = _disputedFromCompleted(bob);
        uint256 c = _accepted(alice);
        vm.prank(buyer);
        market.openDispute(c, REASON);
        _pauseAll();
        vm.prank(alice);
        market.submitProof(c, _proof(c)); // dispute evidence still accepted while paused
        vm.prank(verifier);
        market.resolveDispute(a, ClinovaTypes.Resolution.PROVIDER_WINS);
        vm.warp(vm.getBlockTimestamp() + DISPUTE + 1);
        market.resolveDisputeByTimeout(b);
        vm.prank(verifier);
        market.resolveDispute(c, ClinovaTypes.Resolution.REFUND_NO_FAULT); // late resolution, still paused
        assertEq(escrow.credit(alice), PRICE);
        assertEq(escrow.credit(buyer), 2 * PRICE);
    }

    function test_Pause_BeforeRefundAndProviderWithdrawal() public {
        uint256 paid = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(paid);
        uint256 refunded = _open();
        vm.prank(buyer);
        market.cancelRequest(refunded);
        vm.prank(alice);
        registry.requestUnstake();
        _pauseAll();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        vm.prank(buyer);
        escrow.withdraw();
        vm.prank(alice);
        escrow.withdraw();
        vm.prank(alice);
        registry.withdrawStake();
        vm.prank(bob);
        registry.requestUnstake(); // starting an exit is also allowed while paused
        assertEq(usdc.balanceOf(alice), PRICE + MIN_STAKE);
        _assertEscrowExact(0);
    }

    /// Unpausing restores normal operation; pausing never altered any request.
    function test_Pause_UnpauseResumes() public {
        uint256 id = _open();
        ClinovaTypes.ServiceRequest memory before = _req(id);
        _pauseAll();
        vm.startPrank(pauser);
        market.unpause();
        registry.unpause();
        vm.stopPrank();
        assertEq(abi.encode(_req(id)), abi.encode(before));
        vm.prank(alice);
        market.acceptRequest(id);
    }
}
