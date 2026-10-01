// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClinovaBase} from "./ClinovaBase.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IClinovaEscrow} from "../src/interfaces/IClinovaEscrow.sol";
import {IProofOfService} from "../src/interfaces/IProofOfService.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";

/// @notice Phase 5 §6: deliberate attack sequences by each actor class. Each test names the attack it attempts.
///         Every attack must fail without changing state, except the admin-compromise scenario at the end, which
///         SUCCEEDS and is kept as an executable record of a documented residual risk (security-review R5-1).
contract AdversarialTest is ClinovaBase {
    function _invalid(uint256 id, ClinovaTypes.Status s) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, s);
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    // ------------------------------------------------------------------
    // Buyer attacks
    // ------------------------------------------------------------------

    function test_Buyer_CancelAfterAcceptanceStartOrProof() public {
        uint256 acc = _accepted(alice);
        uint256 svc = _inService(bob);
        uint256 comp = _completed(alice);
        vm.startPrank(buyer);
        vm.expectRevert(_invalid(acc, ClinovaTypes.Status.ACCEPTED));
        market.cancelRequest(acc);
        vm.expectRevert(_invalid(svc, ClinovaTypes.Status.IN_SERVICE));
        market.cancelRequest(svc);
        vm.expectRevert(_invalid(comp, ClinovaTypes.Status.COMPLETED));
        market.cancelRequest(comp);
        vm.stopPrank();
        assertEq(escrow.credit(buyer), 0);
    }

    function test_Buyer_ConfirmTwiceAndAfterRefund() public {
        uint256 id = _completed(alice);
        vm.startPrank(buyer);
        market.confirmCompletion(id);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.SETTLED));
        market.confirmCompletion(id);
        vm.stopPrank();
        assertEq(escrow.credit(alice), PRICE, "paid exactly once");

        uint256 refunded = _completed(bob);
        vm.warp(vm.getBlockTimestamp() + REVIEW + 1);
        market.closeUnreviewed(refunded);
        vm.prank(buyer);
        vm.expectRevert(_invalid(refunded, ClinovaTypes.Status.REFUNDED));
        market.confirmCompletion(refunded);
        assertEq(escrow.credit(bob), 0);
    }

    function test_Buyer_DisputeTwiceAndAfterFinalization() public {
        uint256 id = _accepted(alice);
        vm.startPrank(buyer);
        market.openDispute(id, REASON);
        uint64 firstDeadline = _req(id).disputeDeadline;
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.DISPUTED));
        market.openDispute(id, REASON); // cannot restart the dispute clock
        vm.stopPrank();
        assertEq(_req(id).disputeDeadline, firstDeadline);

        uint256 fin = _completed(bob);
        vm.prank(buyer);
        market.confirmCompletion(fin);
        vm.prank(buyer);
        vm.expectRevert(_invalid(fin, ClinovaTypes.Status.SETTLED));
        market.openDispute(fin, REASON);
    }

    /// Deadlines are validated at creation, immutable afterwards, and unaffected by later admin changes.
    function test_Buyer_ManipulateDeadlines() public {
        uint64 nowTs = uint64(vm.getBlockTimestamp());
        vm.startPrank(buyer);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, nowTs, nowTs + 1 days); // accept now
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, nowTs + 8 days, nowTs + 9 days); // too far
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, nowTs + 2 hours, nowTs + 3 hours); // service window < 6h
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, nowTs + 2 hours, nowTs + 1 hours); // service before accept
        vm.stopPrank();
        uint256 id = _accepted(alice);
        ClinovaTypes.ServiceRequest memory before = _req(id);
        vm.startPrank(admin);
        market.setReviewPeriod(1 days);
        market.setDisputePeriod(3 days);
        market.setMinPrice(10_000e6);
        vm.stopPrank();
        ClinovaTypes.ServiceRequest memory afterR = _req(id);
        assertEq(abi.encode(before), abi.encode(afterR), "request fields are frozen");
    }

    /// The deposit equals the price exactly: no under-funding, and extra tokens sent alongside become surplus.
    function test_Buyer_UnderOrOverfundEscrow() public {
        (uint64 a, uint64 s) = _deadlines();
        address poor = makeAddr("poor");
        _fundBuyer(poor, PRICE - 1);
        vm.prank(poor);
        vm.expectRevert(); // ERC20InsufficientBalance
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.PriceTooLow.selector, MIN_PRICE - 1, MIN_PRICE));
        market.createRequest(address(0), CBC, REGION, uint128(MIN_PRICE - 1), a, s);
        // Over-funding attempt: send extra directly, then create. Deposit is still exactly the price.
        vm.prank(buyer);
        usdc.transfer(address(escrow), 5e6);
        uint256 id = _open();
        assertEq(escrow.getDeposit(id).amount, PRICE);
        vm.prank(buyer);
        market.cancelRequest(id);
        vm.prank(buyer);
        assertEq(escrow.withdraw(), PRICE, "only the price comes back; the extra is unaccounted surplus");
        _assertEscrowExact(5e6);
    }

    function test_Buyer_CannotTakeProviderFunds() public {
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.startPrank(buyer);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdrawTo(buyer);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.refund(id);
        vm.expectRevert(IProviderRegistry.NoUnstakeRequested.selector);
        registry.withdrawStake();
        vm.stopPrank();
        assertEq(escrow.credit(alice), PRICE);
    }

    function test_Buyer_CannotActAsVerifier() public {
        uint256 id = _completed(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(buyer);
        vm.expectRevert(_unauthorized(buyer, role));
        market.approveProof(id);
        vm.prank(admin);
        market.grantRole(role, buyer); // even holding the role
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, buyer));
        market.rejectProof(id, REASON); // cannot reject to force a refund of its own request
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, buyer));
        market.approveProof(id);
    }

    // ------------------------------------------------------------------
    // Provider attacks
    // ------------------------------------------------------------------

    function test_Provider_AcceptTwiceAfterDeadlineOrOthersRequest() public {
        uint256 id = _open();
        vm.prank(alice);
        market.acceptRequest(id);
        vm.prank(alice);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.ACCEPTED));
        market.acceptRequest(id);
        vm.prank(bob);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.ACCEPTED));
        market.acceptRequest(id); // cannot replace alice
        assertEq(_activeJobs(alice), 1);

        uint256 directed = _create(buyer, alice, PRICE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, directed));
        market.acceptRequest(directed);

        uint256 late = _open();
        vm.warp(_req(late).acceptDeadline + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, _req(late).acceptDeadline));
        market.acceptRequest(late);
    }

    function test_Provider_SubmitTwiceAfterRejectionOrForAnotherProvider() public {
        uint256 id = _completed(alice);
        vm.prank(alice);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.COMPLETED));
        market.submitProof(id, keccak256("second"));
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        vm.prank(alice);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.DISPUTED));
        market.submitProof(id, keccak256("after-rejection")); // cannot replace a rejected proof
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.REJECTED));

        uint256 other = _inService(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, other));
        market.submitProof(other, keccak256("bob"));
        vm.prank(address(market)); // even the module path rejects the wrong provider
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProviderMismatch.selector, other, alice, bob));
        pos.submit(other, bob, keccak256("bob"));
    }

    /// Copying another provider's public commitment gains nothing: it is bound to the copier's own request and
    /// address (different proofHash), and the owner can still use it. Opening it would need the owner's salt.
    function test_Provider_CopiesAnotherProvidersCommitment() public {
        bytes32 c = keccak256("alice-evidence");
        uint256 aliceJob = _inService(alice);
        uint256 bobJob = _inService(bob);
        vm.prank(bob);
        market.submitProof(bobJob, c); // squat attempt
        vm.prank(alice);
        market.submitProof(aliceJob, c); // owner unaffected
        bytes32 hA = pos.getProof(aliceJob).proofHash;
        bytes32 hB = pos.getProof(bobJob).proofHash;
        assertTrue(hA != hB, "bound to request and provider");
        assertEq(pos.getProof(bobJob).provider, bob);
        assertEq(pos.getProof(aliceJob).provider, alice);
    }

    function test_Provider_StaleProofReplay() public {
        bytes32 c = keccak256("evidence-1");
        uint256 first = _inService(alice);
        vm.prank(alice);
        market.submitProof(first, c);
        vm.prank(buyer);
        market.confirmCompletion(first);
        uint256 second = _inService(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.EvidenceAlreadyUsed.selector, alice, c));
        market.submitProof(second, c); // even after the first request finished
    }

    function test_Provider_SettleWithoutApproval() public {
        uint256 id = _completed(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotBuyer.selector, id));
        market.confirmCompletion(id);
        vm.expectRevert(_unauthorized(alice, role));
        market.approveProof(id);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.release(id);
        vm.expectRevert(IProofOfService.OnlyMarketplace.selector);
        pos.markBuyerAccepted(id, buyer);
        vm.stopPrank();
        // Waiting out the review window never pays the provider.
        vm.warp(_req(id).reviewDeadline + 1);
        vm.prank(alice);
        market.closeUnreviewed(id);
        assertEq(escrow.credit(alice), 0);
        assertEq(escrow.credit(buyer), PRICE);
    }

    function test_Provider_CloseAnotherProvidersJob() public {
        uint256 id = _accepted(alice);
        vm.warp(_req(id).serviceDeadline + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotParty.selector, id));
        market.expireRequest(id);
        vm.prank(bob);
        vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
        registry.recordJobClosed(id, alice);
        assertEq(_activeJobs(alice), 1);
    }

    function test_Provider_WithdrawStakeWithActiveJobs() public {
        uint256 id = _completed(alice); // obligation still open while the proof awaits review
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ActiveObligation.selector, 1));
        registry.withdrawStake();
        // Once the job is finished (here: the buyer confirms late, before anyone closed it), the stake can leave.
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(usdc.balanceOf(alice), MIN_STAKE);
    }

    /// No sequence of self-service calls (deactivate, revoke, re-verify, profile/capability churn) changes the
    /// obligation count; only acceptance and the marketplace's terminal transitions do.
    function test_Provider_ManipulateActiveJobCount() public {
        uint256 a = _accepted(alice);
        uint256 b = _inService(alice);
        assertEq(_activeJobs(alice), 2);
        vm.startPrank(alice);
        registry.deactivate();
        registry.activate();
        registry.updateProfile(keccak256("new"), REGION); // revokes verification
        registry.addCapability(GLUCOSE);
        registry.removeCapability(GLUCOSE);
        registry.requestUnstake();
        vm.stopPrank();
        vm.prank(verifier);
        registry.verifyProvider(alice);
        assertEq(_activeJobs(alice), 2);
        vm.prank(alice);
        vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
        registry.recordJobClosed(a, alice);
        // Ineligible now (unbonding), but in-flight jobs still close normally.
        vm.prank(alice);
        market.openDispute(a, REASON);
        vm.warp(vm.getBlockTimestamp() + DISPUTE + 1);
        market.resolveDisputeByTimeout(a);
        vm.warp(_req(b).serviceDeadline + 1);
        vm.prank(alice);
        market.expireRequest(b);
        assertEq(_activeJobs(alice), 0);
    }

    /// KNOWN RISK (R5-2), kept executable: a provider that will miss its deadline can open a dispute just before it.
    /// With a live verifier this ends as REFUND_PROVIDER_FAULT (failedJobs +1). With NO verifier the dispute times
    /// out as no-fault, so the provider avoids failedJobs that expiry would have recorded, and the buyer's refund
    /// is delayed by up to disputePeriod. No funds are lost; the `disputes` counter still records the episode.
    function test_Provider_DisputeToAvoidFault_KnownRisk() public {
        uint256 withVerifier = _accepted(alice);
        uint256 withoutVerifier = _accepted(alice);
        vm.warp(_req(withVerifier).serviceDeadline); // last allowed second
        vm.startPrank(alice);
        market.openDispute(withVerifier, REASON);
        market.openDispute(withoutVerifier, REASON);
        vm.stopPrank();
        vm.prank(verifier);
        market.resolveDispute(withVerifier, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        assertEq(rep.getReputation(alice).failedJobs, 1, "a live verifier records the fault");

        vm.warp(_req(withoutVerifier).disputeDeadline + 1);
        market.resolveDisputeByTimeout(withoutVerifier);
        ClinovaTypes.Reputation memory r = rep.getReputation(alice);
        assertEq(r.failedJobs, 1, "RISK: the timeout recorded no fault for the second missed job");
        assertEq(r.disputes, 2, "but both episodes are visible as disputes");
        assertEq(escrow.credit(buyer), 2 * PRICE, "buyer fully refunded");
    }

    // ------------------------------------------------------------------
    // Verifier attacks
    // ------------------------------------------------------------------

    function test_Verifier_ReviewOwnRequestAsBuyerOrProvider() public {
        // Verifier is the buyer.
        _fundBuyer(verifier, 1_000e6);
        uint256 asBuyer = _create(verifier, address(0), PRICE);
        vm.prank(alice);
        market.acceptRequest(asBuyer);
        vm.prank(alice);
        market.startService(asBuyer);
        vm.prank(alice);
        market.submitProof(asBuyer, _proof(asBuyer));
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, verifier));
        market.approveProof(asBuyer);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, verifier));
        market.rejectProof(asBuyer, REASON);
        // Verifier is the provider (another verifier admitted it to the registry).
        address v2 = makeAddr("verifier2");
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), v2);
        vm.stopPrank();
        _registerProvider(verifier);
        vm.prank(v2);
        registry.verifyProvider(verifier);
        vm.prank(verifier);
        registry.activate();
        uint256 asProvider = _completed(verifier);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, verifier));
        market.approveProof(asProvider);
        // And the module re-checks independently.
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ConflictOfInterest.selector, verifier));
        pos.approve(asProvider, verifier);
    }

    function test_Verifier_ActAfterFinalizationOrRejection() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.approveProof(id);
        vm.startPrank(verifier);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.SETTLED));
        market.approveProof(id);
        vm.expectRevert(_invalid(id, ClinovaTypes.Status.SETTLED));
        market.rejectProof(id, REASON); // reject after approval
        vm.stopPrank();

        uint256 rej = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(rej, REASON);
        vm.startPrank(verifier);
        vm.expectRevert(_invalid(rej, ClinovaTypes.Status.DISPUTED));
        market.approveProof(rej); // approve a rejected proof
        vm.expectRevert(
            abi.encodeWithSelector(
                IServiceMarketplace.ProofNotApprovable.selector, rej, ClinovaTypes.ProofStatus.REJECTED
            )
        );
        market.resolveDispute(rej, ClinovaTypes.Resolution.PROVIDER_WINS); // or pay it through the dispute
        vm.stopPrank();
    }

    function test_Verifier_DirectSettlementOrUnauthorizedResolution() public {
        uint256 disp = _disputedFromCompleted(alice);
        address regOnly = makeAddr("registry-verifier");
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), regOnly);
        vm.stopPrank();
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(regOnly);
        vm.expectRevert(_unauthorized(regOnly, role));
        market.resolveDispute(disp, ClinovaTypes.Resolution.PROVIDER_WINS);
        vm.startPrank(verifier);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.release(disp);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.refund(disp);
        vm.expectRevert(IReputationRegistry.OnlyMarketplace.selector);
        rep.recordOutcome(disp, true);
        vm.stopPrank();
    }

    function test_Verifier_RemovedMidFlow() public {
        uint256 comp = _completed(alice);
        uint256 disp = _disputedFromCompleted(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(admin);
        market.revokeRole(role, verifier);
        vm.startPrank(verifier);
        vm.expectRevert(_unauthorized(verifier, role));
        market.approveProof(comp);
        vm.expectRevert(_unauthorized(verifier, role));
        market.resolveDispute(disp, ClinovaTypes.Resolution.PROVIDER_WINS);
        vm.stopPrank();
        vm.prank(address(market)); // PoS reads the live role too
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.NotVerifier.selector, verifier));
        pos.approve(comp, verifier);
        // The exits still work without any verifier.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        market.closeUnreviewed(comp);
        market.resolveDisputeByTimeout(disp);
        assertEq(escrow.credit(buyer), 2 * PRICE);
    }

    // ------------------------------------------------------------------
    // Admin attacks
    // ------------------------------------------------------------------

    /// An admin holding every role on every contract still has no function that moves escrow or stake, edits a
    /// request, sets a proof outcome, or writes reputation.
    function test_Admin_HoldingEveryRoleCannotStealOrRewrite() public {
        uint256 open = _open();
        uint256 comp = _completed(alice);
        vm.startPrank(admin);
        market.grantRole(market.VERIFIER_ROLE(), admin);
        market.grantRole(market.PAUSER_ROLE(), admin);
        registry.grantRole(registry.VERIFIER_ROLE(), admin);
        registry.grantRole(registry.PAUSER_ROLE(), admin);
        ClinovaTypes.ServiceRequest memory before = _req(open);
        // escrow
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.release(comp);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.refund(open);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.assignPayee(open, admin);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        // stake
        vm.expectRevert(IProviderRegistry.NoUnstakeRequested.selector);
        registry.withdrawStake();
        vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
        registry.recordJobClosed(comp, alice);
        // proof and reputation
        vm.expectRevert(IProofOfService.OnlyMarketplace.selector);
        pos.approve(comp, admin);
        vm.expectRevert(IReputationRegistry.OnlyMarketplace.selector);
        rep.recordOutcome(comp, false);
        // request ownership / accepted provider: no setter exists; every admin setter leaves requests untouched
        market.setMinPrice(500e6);
        market.setReviewPeriod(14 days);
        registry.setMinStake(100_000e6);
        registry.setUnbondingPeriod(30 days);
        vm.stopPrank();
        assertEq(abi.encode(_req(open)), abi.encode(before));
        assertEq(_req(comp).provider, alice);
        assertEq(escrow.getDeposit(comp).payee, alice);
        assertEq(usdc.balanceOf(admin) + escrow.credit(admin), 0);
        assertEq(registry.getProvider(alice).stake, MIN_STAKE);
        // An in-flight provider whose stake is now below minStake still completes and exits.
        vm.prank(buyer);
        market.confirmCompletion(comp);
        assertEq(escrow.credit(alice), PRICE);
    }

    /// KNOWN RISK (R5-1), kept executable on purpose: a compromised admin key can grant itself VERIFIER_ROLE on both
    /// the registry and the marketplace, admit a sybil provider, take an undirected OPEN request, and approve its own
    /// fake proof. The attack is bounded (see assertions) but real. Mitigation is operational: a multisig admin
    /// behind a timelock, RoleGranted monitoring, and directed requests for high-value work.
    function test_AdminCompromise_KnownRisk_SybilCanBePaidForUndirectedRequests() public {
        uint256 undirected = _open();
        uint256 directedToAlice = _create(buyer, alice, PRICE);
        uint256 alreadyAccepted = _accepted(bob);
        address sybil = makeAddr("sybil");

        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), admin);
        market.grantRole(market.VERIFIER_ROLE(), admin);
        vm.stopPrank();
        _registerProvider(sybil);
        vm.prank(admin);
        registry.verifyProvider(sybil);
        vm.prank(sybil);
        registry.activate();

        vm.startPrank(sybil);
        market.acceptRequest(undirected);
        market.startService(undirected);
        market.submitProof(undirected, keccak256("fabricated"));
        vm.stopPrank();
        vm.prank(admin);
        market.approveProof(undirected);
        assertEq(escrow.credit(sybil), PRICE, "RISK: undirected request paid to the admin's sybil");

        // Bounds of the attack:
        vm.prank(sybil);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, directedToAlice));
        market.acceptRequest(directedToAlice); // directed requests cannot be taken
        vm.prank(sybil);
        vm.expectRevert(_invalid(alreadyAccepted, ClinovaTypes.Status.ACCEPTED));
        market.acceptRequest(alreadyAccepted); // accepted requests cannot be redirected
        assertEq(escrow.getDeposit(alreadyAccepted).payee, bob);
        assertEq(registry.getProvider(alice).stake, MIN_STAKE, "stake is never reachable");
        assertEq(escrow.credit(admin), 0, "the admin key itself never receives funds");
    }
}
