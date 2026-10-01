// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaBase} from "./ClinovaBase.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IProofOfService} from "../src/interfaces/IProofOfService.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";

/// @notice ReputationRegistry: objective counters, exactly one record per finished accepted request.
contract ReputationRegistryTest is ClinovaBase {
    function _rep(address p) internal view returns (ClinovaTypes.Reputation memory) {
        return rep.getReputation(p);
    }

    function _assertRep(address p, uint64 completed, uint64 successful, uint64 failed, uint64 disputes) internal view {
        ClinovaTypes.Reputation memory r = _rep(p);
        assertEq(r.completedJobs, completed, "completedJobs");
        assertEq(r.successfulJobs, successful, "successfulJobs");
        assertEq(r.failedJobs, failed, "failedJobs");
        assertEq(r.disputes, disputes, "disputes");
    }

    // ------------------------------------------------------------------
    // Construction / authorization
    // ------------------------------------------------------------------

    function test_Constructor() public view {
        assertEq(rep.marketplace(), address(market));
        assertEq(address(rep.registry()), address(registry));
        assertEq(address(rep.proofOfService()), address(pos));
    }

    function test_Constructor_RevertsZeroMarketplace() public {
        vm.expectRevert(IReputationRegistry.ZeroAddress.selector);
        new ReputationRegistry(address(0), registry, pos);
    }

    function test_Constructor_RevertsZeroRegistry() public {
        vm.expectRevert(IReputationRegistry.ZeroAddress.selector);
        new ReputationRegistry(address(market), IProviderRegistry(address(0)), pos);
    }

    function test_Constructor_RevertsZeroProofOfService() public {
        vm.expectRevert(IReputationRegistry.ZeroAddress.selector);
        new ReputationRegistry(address(market), registry, IProofOfService(address(0)));
    }

    function test_OnlyMarketplaceCanRecord() public {
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        address[6] memory callers = [attacker, admin, verifier, alice, buyer, pauser];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IReputationRegistry.OnlyMarketplace.selector);
            rep.recordOutcome(id, true);
        }
        _assertRep(alice, 1, 1, 0, 0);
    }

    // ------------------------------------------------------------------
    // Outcome rules
    // ------------------------------------------------------------------

    function test_SuccessfulJob() public {
        uint256 id = _completed(alice);
        vm.expectEmit(true, true, false, true, address(rep));
        emit IReputationRegistry.OutcomeRecorded(id, alice, IReputationRegistry.Outcome.SUCCESS, true, false);
        vm.expectEmit(true, false, false, true, address(rep));
        emit IReputationRegistry.ReputationUpdated(alice, 1, 1, 0, 0);
        vm.prank(verifier);
        market.approveProof(id);
        assertTrue(rep.outcomeRecorded(id));
        _assertRep(alice, 1, 1, 0, 0);
    }

    function test_FailedJob_MissedDeadline() public {
        uint256 id = _accepted(alice);
        vm.warp(_req(id).serviceDeadline + 1);
        vm.prank(buyer);
        market.expireRequest(id);
        _assertRep(alice, 0, 0, 1, 0);
    }

    function test_Dispute_ProviderAtFault() public {
        uint256 id = _disputedFromCompleted(alice);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        _assertRep(alice, 1, 0, 1, 1);
    }

    function test_Dispute_ProviderNotAtFault() public {
        // A frivolous dispute is recorded as a dispute but never as a failure.
        uint256 id = _disputedFromCompleted(alice);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
        _assertRep(alice, 1, 0, 0, 1);
    }

    function test_Dispute_ProviderWins() public {
        uint256 id = _disputedFromCompleted(alice);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        _assertRep(alice, 1, 1, 0, 1);
    }

    function test_Dispute_TimeoutIsNoFault() public {
        uint256 id = _disputedFromCompleted(alice);
        vm.warp(_req(id).disputeDeadline + 1);
        market.resolveDisputeByTimeout(id);
        _assertRep(alice, 1, 0, 0, 1);
    }

    function test_RejectedProofCountsAsDispute() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        _assertRep(alice, 1, 0, 1, 1);
    }

    function test_UnreviewedCloseIsNoFault() public {
        uint256 id = _completed(alice);
        vm.warp(_req(id).reviewDeadline + 1);
        market.closeUnreviewed(id);
        _assertRep(alice, 1, 0, 0, 0);
    }

    function test_NotRecordedForNeverAcceptedRequests() public {
        uint256 c = _open();
        vm.prank(buyer);
        market.cancelRequest(c);
        uint256 e = _create(buyer, alice, PRICE); // directed, never accepted
        vm.warp(_req(e).acceptDeadline + 1);
        market.expireRequest(e);
        assertFalse(rep.outcomeRecorded(c));
        assertFalse(rep.outcomeRecorded(e));
        _assertRep(alice, 0, 0, 0, 0);
    }

    // ------------------------------------------------------------------
    // Double counting / attribution / validation
    // ------------------------------------------------------------------

    function test_RepeatedOutcomeRejected() public {
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.startPrank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.OutcomeAlreadyRecorded.selector, id));
        rep.recordOutcome(id, false);
        vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.OutcomeAlreadyRecorded.selector, id));
        rep.recordOutcome(id, true);
        vm.stopPrank();
        _assertRep(alice, 1, 1, 0, 0);
    }

    function test_RejectsUnfinishedOrUnknownRequests() public {
        uint256 active = _accepted(alice);
        uint256 open = _open();
        vm.startPrank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.JobNotClosed.selector, active));
        rep.recordOutcome(active, false);
        vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.JobNotClosed.selector, open));
        rep.recordOutcome(open, false);
        vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.JobNotClosed.selector, 0));
        rep.recordOutcome(0, false);
        vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.JobNotClosed.selector, 999));
        rep.recordOutcome(999, false);
        vm.stopPrank();
    }

    /// The provider is taken from the registry binding; a request claiming a different provider is refused.
    function test_RejectsProviderMismatch() public {
        uint256 id = _accepted(alice);
        ClinovaTypes.Job memory closed = ClinovaTypes.Job({provider: alice, status: ClinovaTypes.JobStatus.CLOSED});
        vm.mockCall(address(registry), abi.encodeCall(registry.getJob, (id)), abi.encode(closed));
        ClinovaTypes.ServiceRequest memory r = _req(id);
        r.provider = bob;
        r.status = ClinovaTypes.Status.SETTLED;
        vm.mockCall(address(market), abi.encodeCall(market.getRequest, (id)), abi.encode(r));
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.ProviderMismatch.selector, id, alice, bob));
        rep.recordOutcome(id, false);
    }

    /// Outcome must be consistent with the request status (SETTLED is never a fault, EXPIRED always is,
    /// non-final statuses are never recorded).
    function test_RejectsInconsistentOutcome() public {
        uint256 id = _accepted(alice);
        ClinovaTypes.Job memory closed = ClinovaTypes.Job({provider: alice, status: ClinovaTypes.JobStatus.CLOSED});
        vm.mockCall(address(registry), abi.encodeCall(registry.getJob, (id)), abi.encode(closed));
        ClinovaTypes.ServiceRequest memory r = _req(id);
        ClinovaTypes.Status[3] memory sts =
            [ClinovaTypes.Status.SETTLED, ClinovaTypes.Status.EXPIRED, ClinovaTypes.Status.ACCEPTED];
        bool[3] memory faults = [true, false, false];
        for (uint256 i = 0; i < 3; ++i) {
            r.status = sts[i];
            vm.mockCall(address(market), abi.encodeCall(market.getRequest, (id)), abi.encode(r));
            vm.prank(address(market));
            vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.InvalidOutcome.selector, id, sts[i], faults[i]));
            rep.recordOutcome(id, faults[i]);
        }
        vm.clearMockedCalls();
        _assertRep(alice, 0, 0, 0, 0);
    }

    function test_AttributionIsPerProvider() public {
        uint256 a = _completed(alice);
        uint256 b = _completed(bob);
        vm.prank(buyer);
        market.confirmCompletion(a);
        vm.prank(verifier);
        market.rejectProof(b, REASON);
        vm.prank(verifier);
        market.resolveDispute(b, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        _assertRep(alice, 1, 1, 0, 0);
        _assertRep(bob, 1, 0, 1, 1);
    }

    function test_ManyJobsHistoricalCounters() public {
        uint256 n = 40;
        _fundBuyer(buyer, n * PRICE);
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = _completed(alice);
            if (i % 4 == 0) {
                vm.prank(buyer);
                market.confirmCompletion(id);
            } else if (i % 4 == 1) {
                vm.prank(verifier);
                market.approveProof(id);
            } else if (i % 4 == 2) {
                vm.prank(buyer);
                market.openDispute(id, REASON);
                vm.prank(verifier);
                market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
            } else {
                vm.prank(verifier);
                market.rejectProof(id, REASON);
                vm.prank(verifier);
                market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
            }
        }
        _assertRep(alice, 40, 20, 10, 20);
        assertEq(_activeJobs(alice), 0);
    }

    function test_ReputationModuleHoldsNoFunds() public {
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        assertEq(usdc.balanceOf(address(rep)), 0);
    }
}
