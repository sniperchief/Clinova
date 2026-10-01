// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClinovaBase} from "./ClinovaBase.sol";
import {ProofOfService} from "../src/ProofOfService.sol";
import {IProofOfService} from "../src/interfaces/IProofOfService.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";

/// @notice ProofOfService: lifecycle, binding, replay protection, verifier independence.
/// @dev Direct calls pranked as the marketplace test the module's own defenses (defense in depth), independently
///      of the marketplace's checks.
contract ProofOfServiceTest is ClinovaBase {
    bytes32 internal constant EVIDENCE = keccak256("salted-evidence-commitment");

    function _assertProof(uint256 id, ClinovaTypes.ProofStatus expected) internal view {
        assertEq(uint8(pos.proofStatus(id)), uint8(expected));
    }

    // ------------------------------------------------------------------
    // Construction / authorization
    // ------------------------------------------------------------------

    function test_Constructor() public view {
        assertEq(pos.marketplace(), address(market));
        assertEq(pos.VERIFIER_ROLE(), market.VERIFIER_ROLE());
    }

    function test_Constructor_RevertsZeroMarketplace() public {
        vm.expectRevert(IProofOfService.ZeroAddress.selector);
        new ProofOfService(address(0));
    }

    function test_OnlyMarketplaceCanWrite() public {
        uint256 id = _completed(alice);
        address[5] memory callers = [attacker, admin, verifier, alice, buyer];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IProofOfService.OnlyMarketplace.selector);
            pos.submit(id, alice, EVIDENCE);
            vm.expectRevert(IProofOfService.OnlyMarketplace.selector);
            pos.approve(id, verifier);
            vm.expectRevert(IProofOfService.OnlyMarketplace.selector);
            pos.reject(id, verifier, REASON);
            vm.expectRevert(IProofOfService.OnlyMarketplace.selector);
            pos.markBuyerAccepted(id, buyer);
            vm.expectRevert(IProofOfService.OnlyMarketplace.selector);
            pos.markUnresolved(id);
            vm.stopPrank();
        }
        _assertProof(id, ClinovaTypes.ProofStatus.SUBMITTED);
    }

    // ------------------------------------------------------------------
    // Submission
    // ------------------------------------------------------------------

    function test_Submit_ValidProvider() public {
        uint256 id = _inService(alice);
        vm.prank(alice);
        market.submitProof(id, EVIDENCE);
        ClinovaTypes.ServiceProof memory p = pos.getProof(id);
        assertEq(p.provider, alice);
        assertEq(p.submittedAt, block.timestamp);
        assertEq(p.evidenceCommitment, EVIDENCE);
        assertEq(p.proofHash, pos.computeProofHash(id, alice, EVIDENCE));
        assertEq(p.reviewer, address(0));
        assertEq(p.reviewedAt, 0);
        _assertProof(id, ClinovaTypes.ProofStatus.SUBMITTED);
    }

    function test_Submit_WrongProviderViaMarketplace() public {
        uint256 id = _inService(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, id));
        market.submitProof(id, EVIDENCE);
    }

    function test_Submit_ModuleRejectsWrongProviderEvenFromMarketplace() public {
        uint256 id = _inService(alice);
        vm.startPrank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProviderMismatch.selector, id, alice, bob));
        pos.submit(id, bob, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProviderMismatch.selector, id, alice, address(0)));
        pos.submit(id, address(0), EVIDENCE);
        vm.stopPrank();
    }

    function test_Submit_ModuleRejectsWrongRequest() public {
        uint256 open = _open(); // no provider yet
        vm.startPrank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProviderMismatch.selector, open, address(0), alice));
        pos.submit(open, alice, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProviderMismatch.selector, 999, address(0), alice));
        pos.submit(999, alice, EVIDENCE); // nonexistent request
        vm.stopPrank();
    }

    function test_Submit_ZeroCommitment() public {
        uint256 id = _inService(alice);
        vm.prank(alice);
        vm.expectRevert(IProofOfService.InvalidCommitment.selector);
        market.submitProof(id, bytes32(0));
    }

    function test_Submit_DuplicateProofForRequest() public {
        uint256 id = _inService(alice);
        vm.prank(alice);
        market.submitProof(id, EVIDENCE);
        // The marketplace no longer accepts proofs for a COMPLETED request...
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.COMPLETED)
        );
        market.submitProof(id, keccak256("other"));
        // ...and the module itself refuses to overwrite the proof.
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofAlreadySubmitted.selector, id));
        pos.submit(id, alice, keccak256("other"));
        assertEq(pos.getProof(id).evidenceCommitment, EVIDENCE);
    }

    function test_Submit_ReplayAcrossRequestsBlocked() public {
        uint256 a = _inService(alice);
        uint256 b = _inService(alice);
        vm.prank(alice);
        market.submitProof(a, EVIDENCE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.EvidenceAlreadyUsed.selector, alice, EVIDENCE));
        market.submitProof(b, EVIDENCE);
    }

    function test_Submit_OtherProviderCannotBurnCommitment() public {
        uint256 a = _inService(alice);
        uint256 b = _inService(bob);
        vm.prank(bob);
        market.submitProof(b, EVIDENCE); // bob copies alice's commitment first
        vm.prank(alice);
        market.submitProof(a, EVIDENCE); // still accepted for alice
        assertTrue(pos.getProof(a).proofHash != pos.getProof(b).proofHash, "bound hashes differ");
    }

    function test_ProofHash_BindsRequestProviderChainAndContract() public {
        bytes32 h = pos.computeProofHash(1, alice, EVIDENCE);
        assertTrue(h != pos.computeProofHash(2, alice, EVIDENCE), "request");
        assertTrue(h != pos.computeProofHash(1, bob, EVIDENCE), "provider");
        assertTrue(h != pos.computeProofHash(1, alice, keccak256("x")), "commitment");
        ProofOfService other = new ProofOfService(address(market));
        assertTrue(h != other.computeProofHash(1, alice, EVIDENCE), "contract");
        vm.chainId(421614);
        assertTrue(h != pos.computeProofHash(1, alice, EVIDENCE), "chain");
        assertEq(
            pos.computeProofHash(1, alice, EVIDENCE),
            keccak256(abi.encode(pos.PROOF_DOMAIN(), uint256(421614), address(pos), uint256(1), alice, EVIDENCE))
        );
    }

    function test_Submit_BlockedInTerminalOrWrongStates() public {
        // cancelled
        uint256 c = _open();
        vm.prank(buyer);
        market.cancelRequest(c);
        // expired (after acceptance)
        uint256 e = _inService(alice);
        // settled
        uint256 s = _completed(bob);
        vm.prank(buyer);
        market.confirmCompletion(s);
        // refunded
        uint256 r = _disputedFromCompleted(alice);
        vm.prank(verifier);
        market.resolveDispute(r, ClinovaTypes.Resolution.REFUND_NO_FAULT);
        vm.warp(_req(e).serviceDeadline + 1);
        vm.prank(buyer);
        market.expireRequest(e);

        uint256[4] memory ids_ = [c, e, s, r];
        ClinovaTypes.Status[4] memory sts = [
            ClinovaTypes.Status.CANCELLED,
            ClinovaTypes.Status.EXPIRED,
            ClinovaTypes.Status.SETTLED,
            ClinovaTypes.Status.REFUNDED
        ];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, ids_[i], sts[i]));
            market.submitProof(ids_[i], keccak256(abi.encode("late", i)));
        }
    }

    // ------------------------------------------------------------------
    // Review
    // ------------------------------------------------------------------

    function test_Approve() public {
        uint256 id = _completed(alice);
        bytes32 h = pos.getProof(id).proofHash;
        vm.expectEmit(true, true, true, true, address(pos));
        emit IProofOfService.ProofApproved(id, alice, verifier, h);
        vm.prank(verifier);
        market.approveProof(id);
        _assertProof(id, ClinovaTypes.ProofStatus.APPROVED);
        assertEq(pos.getProof(id).reviewer, verifier);
        assertEq(pos.getProof(id).reviewedAt, block.timestamp);
    }

    function test_Approve_UnauthorizedVerifier() public {
        uint256 id = _completed(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role)
        );
        market.approveProof(id);
        // Module check: the named verifier must hold the marketplace role.
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.NotVerifier.selector, attacker));
        pos.approve(id, attacker);
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.NotVerifier.selector, attacker));
        pos.reject(id, attacker, REASON);
    }

    function test_BuyerAndProviderCannotVerify() public {
        uint256 id = _completed(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.startPrank(admin);
        market.grantRole(role, buyer);
        market.grantRole(role, alice);
        vm.stopPrank();
        address[2] memory parties = [buyer, alice];
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(parties[i]);
            vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, parties[i]));
            market.approveProof(id);
            vm.prank(parties[i]);
            vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, parties[i]));
            market.rejectProof(id, REASON);
            // Independent module check.
            vm.startPrank(address(market));
            vm.expectRevert(abi.encodeWithSelector(IProofOfService.ConflictOfInterest.selector, parties[i]));
            pos.approve(id, parties[i]);
            vm.expectRevert(abi.encodeWithSelector(IProofOfService.ConflictOfInterest.selector, parties[i]));
            pos.reject(id, parties[i], REASON);
            vm.stopPrank();
        }
        _assertProof(id, ClinovaTypes.ProofStatus.SUBMITTED);
    }

    function test_Reject() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        _assertProof(id, ClinovaTypes.ProofStatus.REJECTED);
        assertEq(pos.getProof(id).reviewer, verifier);
    }

    function test_RepeatedApprovalAndRejectionAfterApproval() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.approveProof(id);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.SETTLED)
        );
        market.approveProof(id);
        bytes memory notReviewable =
            abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, ClinovaTypes.ProofStatus.APPROVED);
        vm.startPrank(address(market));
        vm.expectRevert(notReviewable);
        pos.approve(id, verifier);
        vm.expectRevert(notReviewable);
        pos.reject(id, verifier, REASON); // an approved proof can never become rejected
        vm.expectRevert(notReviewable);
        pos.markUnresolved(id);
        vm.stopPrank();
        _assertProof(id, ClinovaTypes.ProofStatus.APPROVED);
    }

    function test_RepeatedRejectionAndApprovalAfterRejection() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        bytes memory notReviewable =
            abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, ClinovaTypes.ProofStatus.REJECTED);
        vm.startPrank(address(market));
        vm.expectRevert(notReviewable);
        pos.reject(id, verifier, REASON);
        vm.expectRevert(notReviewable);
        pos.approve(id, verifier);
        vm.expectRevert(notReviewable);
        pos.markBuyerAccepted(id, buyer);
        vm.stopPrank();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                IServiceMarketplace.ProofNotApprovable.selector, id, ClinovaTypes.ProofStatus.REJECTED
            )
        );
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        _assertProof(id, ClinovaTypes.ProofStatus.REJECTED);
    }

    function test_BuyerAcceptance() public {
        uint256 id = _completed(alice);
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.BuyerMismatch.selector, id, buyer, buyer2));
        pos.markBuyerAccepted(id, buyer2);
        bytes32 h = pos.getProof(id).proofHash;
        vm.expectEmit(true, true, true, true, address(pos));
        emit IProofOfService.ProofAcceptedByBuyer(id, alice, buyer, h);
        vm.prank(buyer);
        market.confirmCompletion(id);
        _assertProof(id, ClinovaTypes.ProofStatus.BUYER_ACCEPTED);
        assertEq(pos.getProof(id).reviewer, buyer);
    }

    function test_Unresolved() public {
        uint256 id = _completed(alice);
        vm.warp(_req(id).reviewDeadline + 1);
        vm.expectEmit(true, true, false, true, address(pos));
        emit IProofOfService.ProofUnresolved(id, alice, pos.getProof(id).proofHash);
        market.closeUnreviewed(id);
        _assertProof(id, ClinovaTypes.ProofStatus.UNRESOLVED);
        assertEq(pos.getProof(id).reviewer, address(0));
    }

    function test_NoProofNotReviewable() public {
        uint256 id = _inService(alice);
        bytes memory err =
            abi.encodeWithSelector(IProofOfService.ProofNotReviewable.selector, id, ClinovaTypes.ProofStatus.NONE);
        vm.startPrank(address(market));
        vm.expectRevert(err);
        pos.approve(id, verifier);
        vm.expectRevert(err);
        pos.markUnresolved(id);
        vm.stopPrank();
    }

    function test_ProofModuleHoldsNoFunds() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.approveProof(id);
        assertEq(usdc.balanceOf(address(pos)), 0);
    }
}
