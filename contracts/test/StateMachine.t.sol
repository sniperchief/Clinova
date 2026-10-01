// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaBase} from "./ClinovaBase.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {IClinovaEscrow} from "../src/interfaces/IClinovaEscrow.sol";
import {IProofOfService} from "../src/interfaces/IProofOfService.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";

/// @notice Phase 5 §17: state-machine exhaustion. Every (request state x lifecycle action) pair is executed from a
///         fresh snapshot with the caller and timing most favourable to success, and compared against an explicit
///         expected-transition table derived from docs/contract-spec.md §1. After every successful transition the
///         five modules must agree (escrow state, proof status, registry job, reputation record).
///         The proof, escrow and registry-job machines are then driven directly as the marketplace, so each
///         module's own state machine is shown to defend itself independently of the marketplace's checks.
contract StateMachineTest is ClinovaBase {
    enum S {
        NONE,
        OPEN,
        ACCEPTED,
        IN_SERVICE,
        COMPLETED,
        DISPUTED_FROM_ACCEPTED,
        DISPUTED_FROM_ACCEPTED_WITH_PROOF,
        DISPUTED_FROM_IN_SERVICE,
        DISPUTED_FROM_COMPLETED,
        DISPUTED_REJECTED,
        SETTLED,
        CANCELLED,
        EXPIRED_OPEN,
        EXPIRED_ACCEPTED,
        REFUNDED
    }

    enum A {
        CANCEL,
        ACCEPT,
        START,
        SUBMIT,
        CONFIRM,
        APPROVE,
        REJECT,
        DISPUTE_BUYER,
        DISPUTE_PROVIDER,
        EXPIRE_ANYONE,
        EXPIRE_PARTY,
        CLOSE_UNREVIEWED,
        TIMEOUT,
        RESOLVE_PW,
        RESOLVE_PF,
        RESOLVE_NF
    }

    uint8 internal constant REVERTS = type(uint8).max;
    uint256 internal constant N_ACTIONS = 16;
    uint256 internal nonce;

    // ------------------------------------------------------------------
    // Expected transition table (spec §1). Anything not listed must revert.
    // ------------------------------------------------------------------

    function _expected(S s, A a) internal pure returns (uint8) {
        if (s == S.OPEN) {
            if (a == A.CANCEL) return uint8(ClinovaTypes.Status.CANCELLED);
            if (a == A.ACCEPT) return uint8(ClinovaTypes.Status.ACCEPTED);
            if (a == A.EXPIRE_ANYONE || a == A.EXPIRE_PARTY) return uint8(ClinovaTypes.Status.EXPIRED);
        } else if (s == S.ACCEPTED || s == S.IN_SERVICE) {
            if (s == S.ACCEPTED && a == A.START) return uint8(ClinovaTypes.Status.IN_SERVICE);
            if (s == S.IN_SERVICE && a == A.SUBMIT) return uint8(ClinovaTypes.Status.COMPLETED);
            if (a == A.DISPUTE_BUYER || a == A.DISPUTE_PROVIDER) return uint8(ClinovaTypes.Status.DISPUTED);
            if (a == A.EXPIRE_PARTY) return uint8(ClinovaTypes.Status.EXPIRED); // never by a non-party
        } else if (s == S.COMPLETED) {
            if (a == A.CONFIRM || a == A.APPROVE) return uint8(ClinovaTypes.Status.SETTLED);
            if (a == A.REJECT || a == A.DISPUTE_BUYER) return uint8(ClinovaTypes.Status.DISPUTED);
            if (a == A.CLOSE_UNREVIEWED) return uint8(ClinovaTypes.Status.REFUNDED);
        } else if (
            s == S.DISPUTED_FROM_ACCEPTED || s == S.DISPUTED_FROM_ACCEPTED_WITH_PROOF || s == S.DISPUTED_FROM_IN_SERVICE
                || s == S.DISPUTED_FROM_COMPLETED || s == S.DISPUTED_REJECTED
        ) {
            bool proofUnderReview = s == S.DISPUTED_FROM_ACCEPTED_WITH_PROOF || s == S.DISPUTED_FROM_COMPLETED;
            bool noProofYet = s == S.DISPUTED_FROM_ACCEPTED || s == S.DISPUTED_FROM_IN_SERVICE;
            if (a == A.SUBMIT && noProofYet) return uint8(ClinovaTypes.Status.DISPUTED); // evidence into dispute
            if (a == A.RESOLVE_PW && proofUnderReview) return uint8(ClinovaTypes.Status.SETTLED);
            if (a == A.RESOLVE_PF || a == A.RESOLVE_NF || a == A.TIMEOUT) return uint8(ClinovaTypes.Status.REFUNDED);
        }
        // NONE and every terminal state: everything reverts
        return REVERTS;
    }

    // ------------------------------------------------------------------
    // State construction (provider: alice)
    // ------------------------------------------------------------------

    function _build(S s) internal returns (uint256 id) {
        if (s == S.NONE) return market.nextRequestId() + 100;
        if (s == S.OPEN) return _open();
        if (s == S.ACCEPTED) return _accepted(alice);
        if (s == S.IN_SERVICE) return _inService(alice);
        if (s == S.COMPLETED) return _completed(alice);
        if (s == S.DISPUTED_FROM_ACCEPTED || s == S.DISPUTED_FROM_ACCEPTED_WITH_PROOF) {
            id = _accepted(alice);
            vm.prank(buyer);
            market.openDispute(id, REASON);
            if (s == S.DISPUTED_FROM_ACCEPTED_WITH_PROOF) {
                vm.prank(alice);
                market.submitProof(id, _proof(id));
            }
            return id;
        }
        if (s == S.DISPUTED_FROM_IN_SERVICE) {
            id = _inService(alice);
            vm.prank(alice);
            market.openDispute(id, REASON);
            return id;
        }
        if (s == S.DISPUTED_FROM_COMPLETED) return _disputedFromCompleted(alice);
        if (s == S.DISPUTED_REJECTED) {
            id = _completed(alice);
            vm.prank(verifier);
            market.rejectProof(id, REASON);
            return id;
        }
        if (s == S.SETTLED) {
            id = _completed(alice);
            vm.prank(buyer);
            market.confirmCompletion(id);
            return id;
        }
        if (s == S.CANCELLED) {
            id = _open();
            vm.prank(buyer);
            market.cancelRequest(id);
            return id;
        }
        if (s == S.EXPIRED_OPEN) {
            id = _open();
            vm.warp(vm.getBlockTimestamp() + 2 days);
            market.expireRequest(id);
            return id;
        }
        if (s == S.EXPIRED_ACCEPTED) {
            id = _accepted(alice);
            vm.warp(vm.getBlockTimestamp() + 5 days);
            vm.prank(buyer);
            market.expireRequest(id);
            return id;
        }
        // REFUNDED
        id = _disputedFromCompleted(alice);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
    }

    // ------------------------------------------------------------------
    // Action execution with the most favourable caller and timing
    // ------------------------------------------------------------------

    function _act(A a, uint256 id) internal returns (bool ok) {
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        address prov = r.provider == address(0) ? alice : r.provider;
        address who;
        bytes memory data;
        if (a == A.CANCEL) {
            (who, data) = (buyer, abi.encodeCall(market.cancelRequest, (id)));
        } else if (a == A.ACCEPT) {
            (who, data) = (alice, abi.encodeCall(market.acceptRequest, (id)));
        } else if (a == A.START) {
            (who, data) = (prov, abi.encodeCall(market.startService, (id)));
        } else if (a == A.SUBMIT) {
            (who, data) = (prov, abi.encodeCall(market.submitProof, (id, keccak256(abi.encode("sm", ++nonce)))));
        } else if (a == A.CONFIRM) {
            (who, data) = (buyer, abi.encodeCall(market.confirmCompletion, (id)));
        } else if (a == A.APPROVE) {
            (who, data) = (verifier, abi.encodeCall(market.approveProof, (id)));
        } else if (a == A.REJECT) {
            (who, data) = (verifier, abi.encodeCall(market.rejectProof, (id, REASON)));
        } else if (a == A.DISPUTE_BUYER) {
            (who, data) = (buyer, abi.encodeCall(market.openDispute, (id, REASON)));
        } else if (a == A.DISPUTE_PROVIDER) {
            (who, data) = (prov, abi.encodeCall(market.openDispute, (id, REASON)));
        } else if (a == A.RESOLVE_PW) {
            (who, data) = (verifier, abi.encodeCall(market.resolveDispute, (id, ClinovaTypes.Resolution.PROVIDER_WINS)));
        } else if (a == A.RESOLVE_PF) {
            (who, data) =
            (verifier, abi.encodeCall(market.resolveDispute, (id, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT)));
        } else if (a == A.RESOLVE_NF) {
            (who, data) =
            (verifier, abi.encodeCall(market.resolveDispute, (id, ClinovaTypes.Resolution.REFUND_NO_FAULT)));
        } else {
            // Time-gated exits: strictly past every deadline the request can have.
            vm.warp(vm.getBlockTimestamp() + 200 days);
            if (a == A.EXPIRE_ANYONE) (who, data) = (attacker, abi.encodeCall(market.expireRequest, (id)));
            else if (a == A.EXPIRE_PARTY) (who, data) = (buyer, abi.encodeCall(market.expireRequest, (id)));
            else if (a == A.CLOSE_UNREVIEWED) (who, data) = (attacker, abi.encodeCall(market.closeUnreviewed, (id)));
            else (who, data) = (attacker, abi.encodeCall(market.resolveDisputeByTimeout, (id)));
        }
        vm.prank(who);
        (ok,) = address(market).call(data);
    }

    // ------------------------------------------------------------------
    // Cross-module agreement after any transition
    // ------------------------------------------------------------------

    function _assertModulesAgree(uint256 id) internal view {
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        ClinovaTypes.Deposit memory d = escrow.getDeposit(id);
        ClinovaTypes.Job memory job = registry.getJob(id);
        ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
        assertEq(d.amount, r.price, "deposit == price");
        // escrow
        if (r.status == ClinovaTypes.Status.SETTLED) {
            assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.RELEASED));
        } else if (ClinovaTypes.isTerminal(r.status)) {
            assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.REFUNDED));
        } else {
            assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.FUNDED));
        }
        // provider binding
        bool everAccepted = job.status != ClinovaTypes.JobStatus.NONE;
        if (everAccepted) {
            assertEq(job.provider, r.provider);
            assertEq(d.payee, r.provider);
        } else {
            assertEq(d.payee, address(0));
        }
        bool live = r.status == ClinovaTypes.Status.ACCEPTED || r.status == ClinovaTypes.Status.IN_SERVICE
            || r.status == ClinovaTypes.Status.COMPLETED || r.status == ClinovaTypes.Status.DISPUTED;
        if (live) assertEq(uint8(job.status), uint8(ClinovaTypes.JobStatus.OPEN));
        else if (everAccepted) assertEq(uint8(job.status), uint8(ClinovaTypes.JobStatus.CLOSED));
        assertEq(rep.outcomeRecorded(id), job.status == ClinovaTypes.JobStatus.CLOSED, "one outcome per closed job");
        // proof
        bool paid = ps == ClinovaTypes.ProofStatus.APPROVED || ps == ClinovaTypes.ProofStatus.BUYER_ACCEPTED;
        assertEq(r.status == ClinovaTypes.Status.SETTLED, paid, "SETTLED <=> positive acceptance");
        if (ClinovaTypes.isTerminal(r.status)) assertTrue(ps != ClinovaTypes.ProofStatus.SUBMITTED);
        if (r.status == ClinovaTypes.Status.COMPLETED) assertEq(uint8(ps), uint8(ClinovaTypes.ProofStatus.SUBMITTED));
        if (ps != ClinovaTypes.ProofStatus.NONE) assertEq(pos.getProof(id).provider, r.provider);
    }

    function _runRow(S s) internal {
        uint256 id = _build(s);
        ClinovaTypes.Status before = market.getRequest(id).status;
        ClinovaTypes.ProofStatus proofBefore = pos.proofStatus(id);
        for (uint256 i = 0; i < N_ACTIONS; ++i) {
            A a = A(i);
            uint256 snap = vm.snapshotState();
            bool ok = _act(a, id);
            uint8 want = _expected(s, a);
            if (want == REVERTS) {
                assertFalse(
                    ok, string.concat("unexpected success: state ", vm.toString(uint8(s)), " action ", vm.toString(i))
                );
                assertEq(uint8(market.getRequest(id).status), uint8(before), "a revert never changes status");
                assertEq(uint8(pos.proofStatus(id)), uint8(proofBefore));
            } else {
                assertTrue(
                    ok, string.concat("unexpected revert: state ", vm.toString(uint8(s)), " action ", vm.toString(i))
                );
                assertEq(uint8(market.getRequest(id).status), want, "wrong destination");
                _assertModulesAgree(id);
            }
            vm.revertToState(snap);
        }
    }

    function test_Matrix_None() public {
        _runRow(S.NONE);
    }

    function test_Matrix_Open() public {
        _runRow(S.OPEN);
    }

    function test_Matrix_Accepted() public {
        _runRow(S.ACCEPTED);
    }

    function test_Matrix_InService() public {
        _runRow(S.IN_SERVICE);
    }

    function test_Matrix_Completed() public {
        _runRow(S.COMPLETED);
    }

    function test_Matrix_DisputedFromAccepted() public {
        _runRow(S.DISPUTED_FROM_ACCEPTED);
    }

    function test_Matrix_DisputedFromAcceptedWithProof() public {
        _runRow(S.DISPUTED_FROM_ACCEPTED_WITH_PROOF);
    }

    function test_Matrix_DisputedFromInService() public {
        _runRow(S.DISPUTED_FROM_IN_SERVICE);
    }

    function test_Matrix_DisputedFromCompleted() public {
        _runRow(S.DISPUTED_FROM_COMPLETED);
    }

    function test_Matrix_DisputedRejected() public {
        _runRow(S.DISPUTED_REJECTED);
    }

    function test_Matrix_Settled() public {
        _runRow(S.SETTLED);
    }

    function test_Matrix_Cancelled() public {
        _runRow(S.CANCELLED);
    }

    function test_Matrix_ExpiredOpen() public {
        _runRow(S.EXPIRED_OPEN);
    }

    function test_Matrix_ExpiredAccepted() public {
        _runRow(S.EXPIRED_ACCEPTED);
    }

    function test_Matrix_Refunded() public {
        _runRow(S.REFUNDED);
    }

    /// Every state is reachable and every terminal state is absorbing even after a second, different exit.
    function test_TerminalStatesAreAbsorbing() public {
        S[5] memory terminals = [S.SETTLED, S.CANCELLED, S.EXPIRED_OPEN, S.EXPIRED_ACCEPTED, S.REFUNDED];
        for (uint256 t = 0; t < terminals.length; ++t) {
            uint256 id = _build(terminals[t]);
            ClinovaTypes.Status st = market.getRequest(id).status;
            for (uint256 i = 0; i < N_ACTIONS; ++i) {
                assertFalse(_act(A(i), id));
                assertEq(uint8(market.getRequest(id).status), uint8(st));
            }
        }
    }

    // ------------------------------------------------------------------
    // ProofOfService machine, driven directly as the marketplace
    // ------------------------------------------------------------------

    /// From each final proof state, no PoS write (even by the marketplace itself) can change it.
    function test_ProofMachine_FinalStatesAreImmutable() public {
        uint256[4] memory ids;
        // APPROVED
        ids[0] = _completed(alice);
        vm.prank(verifier);
        market.approveProof(ids[0]);
        // BUYER_ACCEPTED
        ids[1] = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(ids[1]);
        // REJECTED
        ids[2] = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(ids[2], REASON);
        // UNRESOLVED
        ids[3] = _completed(alice);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        market.closeUnreviewed(ids[3]);

        for (uint256 i = 0; i < 4; ++i) {
            uint256 id = ids[i];
            ClinovaTypes.ProofStatus st = pos.proofStatus(id);
            assertTrue(st != ClinovaTypes.ProofStatus.SUBMITTED && st != ClinovaTypes.ProofStatus.NONE);
            vm.startPrank(address(market));
            vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, st));
            pos.approve(id, verifier);
            vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, st));
            pos.reject(id, verifier, REASON);
            vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, st));
            pos.markBuyerAccepted(id, buyer);
            vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, st));
            pos.markUnresolved(id);
            vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofAlreadySubmitted.selector, id));
            pos.submit(id, alice, keccak256("fresh"));
            vm.stopPrank();
            assertEq(uint8(pos.proofStatus(id)), uint8(st));
        }
    }

    /// NONE cannot be reviewed; SUBMITTED cannot be re-submitted.
    function test_ProofMachine_NoneAndSubmitted() public {
        uint256 id = _inService(alice);
        vm.startPrank(address(market));
        vm.expectRevert(
            abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, ClinovaTypes.ProofStatus.NONE)
        );
        pos.approve(id, verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, ClinovaTypes.ProofStatus.NONE)
        );
        pos.markUnresolved(id);
        pos.submit(id, alice, keccak256("c1"));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofAlreadySubmitted.selector, id));
        pos.submit(id, alice, keccak256("c2"));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Escrow machine, driven directly as the marketplace
    // ------------------------------------------------------------------

    function test_EscrowMachine_EveryStateAndCall() public {
        uint256 id = 9_999; // id the marketplace never issued
        usdc.mint(address(escrow), 10e6); // tokens present so lock can succeed
        vm.startPrank(address(market));
        // NONE
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, id, ClinovaTypes.EscrowState.NONE)
        );
        escrow.assignPayee(id, alice);
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, id, ClinovaTypes.EscrowState.NONE)
        );
        escrow.release(id);
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, id, ClinovaTypes.EscrowState.NONE)
        );
        escrow.refund(id);
        escrow.lock(id, buyer, 10e6); // NONE -> FUNDED
        // FUNDED, no payee
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, id, ClinovaTypes.EscrowState.FUNDED)
        );
        escrow.lock(id, buyer, 10e6);
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.PayeeNotAssigned.selector, id));
        escrow.release(id);
        escrow.assignPayee(id, alice);
        // FUNDED, payee bound
        vm.expectRevert(abi.encodeWithSelector(IClinovaEscrow.PayeeAlreadyAssigned.selector, id));
        escrow.assignPayee(id, bob);
        uint256 snap = vm.snapshotState();
        escrow.release(id); // -> RELEASED
        _assertEscrowTerminal(id, ClinovaTypes.EscrowState.RELEASED);
        vm.revertToState(snap);
        vm.startPrank(address(market));
        escrow.refund(id); // -> REFUNDED
        _assertEscrowTerminal(id, ClinovaTypes.EscrowState.REFUNDED);
        vm.stopPrank();
    }

    function _assertEscrowTerminal(uint256 id, ClinovaTypes.EscrowState st) internal {
        bytes memory err = abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, id, st);
        vm.expectRevert(err);
        escrow.lock(id, buyer, 1);
        vm.expectRevert(err);
        escrow.assignPayee(id, bob);
        vm.expectRevert(err);
        escrow.release(id);
        vm.expectRevert(err);
        escrow.refund(id);
        assertEq(uint8(escrow.getDeposit(id).state), uint8(st));
    }

    // ------------------------------------------------------------------
    // Registry job machine, driven directly as the marketplace
    // ------------------------------------------------------------------

    function test_JobMachine_EveryStateAndCall() public {
        uint256 id = 8_888;
        vm.startPrank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobNotOpen.selector, id));
        registry.recordJobClosed(id, alice); // NONE cannot close
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, carol, CBC));
        registry.recordJobAccepted(id, carol, CBC); // ineligible cannot open
        registry.recordJobAccepted(id, alice, CBC); // NONE -> OPEN
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobAlreadyRecorded.selector, id));
        registry.recordJobAccepted(id, bob, CBC); // no re-binding
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobProviderMismatch.selector, id, alice, bob));
        registry.recordJobClosed(id, bob); // another provider cannot close it
        registry.recordJobClosed(id, alice); // OPEN -> CLOSED
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobNotOpen.selector, id));
        registry.recordJobClosed(id, alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobAlreadyRecorded.selector, id));
        registry.recordJobAccepted(id, alice, CBC); // CLOSED never reopens
        vm.stopPrank();
        assertEq(_activeJobs(alice), 0);
        assertEq(_activeJobs(bob), 0);
    }
}
