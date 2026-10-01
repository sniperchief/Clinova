// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClinovaBase} from "./ClinovaBase.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";

/// @notice End-to-end flows across ProviderRegistry, ServiceMarketplace and ClinovaEscrow.
contract IntegrationTest is ClinovaBase {
    address internal dave = makeAddr("dave");

    function test_Deploy_WiringIsConsistent() public view {
        assertEq(registry.marketplace(), address(market));
        assertEq(escrow.marketplace(), address(market));
        assertEq(address(market.registry()), address(registry));
        assertEq(address(market.escrow()), address(escrow));
        assertEq(address(registry.usdc()), address(usdc));
        assertEq(address(escrow.usdc()), address(usdc));
    }

    function test_Deploy_ScriptRedeploysCleanly() public {
        Deploy d = new Deploy();
        Deploy.Deployment memory out = d.deploy(_config(address(usdc)), address(d));
        assertEq(out.registry.marketplace(), address(out.marketplace));
        assertEq(out.escrow.marketplace(), address(out.marketplace));
    }

    /// register -> verify -> activate -> create -> accept (activeJobs = 1) -> settle (activeJobs = 0)
    /// -> provider withdraws payment -> unstake -> withdraw stake.
    function test_FullLifecycle_ProviderEarnsAndExits() public {
        _registerProvider(dave);
        vm.prank(verifier);
        registry.verifyProvider(dave);
        vm.prank(dave);
        registry.activate();

        uint256 id = _open();
        vm.prank(dave);
        market.acceptRequest(id);
        assertEq(_activeJobs(dave), 1);

        vm.startPrank(dave);
        market.startService(id);
        market.submitProof(id, _proof(id));
        vm.stopPrank();
        vm.prank(buyer);
        market.confirmCompletion(id);
        assertEq(_activeJobs(dave), 0);

        vm.startPrank(dave);
        escrow.withdraw();
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        registry.withdrawStake();
        vm.stopPrank();

        assertEq(usdc.balanceOf(dave), PRICE + MIN_STAKE, "payment + full stake returned");
        _assertEscrowExact(0);
    }

    /// accept -> deadline missed -> expire -> job closed -> buyer refunded -> provider can exit.
    function test_ExpiryClosesJobAndRefunds() public {
        uint256 id = _accepted(alice);
        assertEq(_activeJobs(alice), 1);
        vm.warp(_req(id).serviceDeadline + 1);
        vm.prank(buyer);
        market.expireRequest(id);
        assertEq(_activeJobs(alice), 0);
        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdc.balanceOf(buyer), before + PRICE);

        vm.startPrank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        registry.withdrawStake();
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), MIN_STAKE);
    }

    function test_StakeLockedWhileJobActive() public {
        uint256 id = _inService(alice);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ActiveObligation.selector, 1));
        registry.withdrawStake();

        // Unstaking provider cannot take new work, but the existing job completes normally.
        uint256 other = _open();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, CBC));
        market.acceptRequest(other);

        uint64 serviceDeadline = _req(id).serviceDeadline;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, serviceDeadline));
        market.submitProof(id, _proof(id)); // deadline passed during unbonding: job must be expired instead
        vm.prank(alice);
        market.expireRequest(id);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(usdc.balanceOf(alice), MIN_STAKE);
    }

    function test_InvalidScenarios() public {
        uint256 id = _open();
        // unverified provider
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, carol, CBC));
        market.acceptRequest(id);
        // inactive provider
        vm.prank(bob);
        registry.deactivate();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, bob, CBC));
        market.acceptRequest(id);

        vm.prank(alice);
        market.acceptRequest(id);
        // wrong provider cannot close (registry defends itself even against the marketplace address)
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobProviderMismatch.selector, id, alice, bob));
        registry.recordJobClosed(id, bob);

        vm.startPrank(alice);
        market.startService(id);
        market.submitProof(id, _proof(id));
        vm.stopPrank();
        vm.prank(buyer);
        market.confirmCompletion(id);
        // already-closed job cannot be closed again
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobNotOpen.selector, id));
        registry.recordJobClosed(id, alice);
        assertEq(_activeJobs(alice), 0);
    }

    function test_VerificationRevokedMidJob_JobStillCompletes() public {
        uint256 id = _inService(alice);
        vm.prank(verifier);
        registry.revokeVerification(alice);
        assertFalse(registry.isEligible(alice, CBC));
        vm.prank(alice);
        market.submitProof(id, _proof(id));
        vm.prank(verifier);
        market.approveProof(id);
        assertEq(escrow.credit(alice), PRICE);
        assertEq(_activeJobs(alice), 0);
    }

    function test_StakeAndEscrowCustodyAreSeparate() public {
        uint256 id = _completed(alice);
        _open();
        uint256 stakes = registry.totalStaked();
        assertEq(usdc.balanceOf(address(registry)), stakes, "registry holds only stake");
        assertEq(usdc.balanceOf(address(escrow)), 2 * PRICE, "escrow holds only payments");
        vm.prank(buyer);
        market.confirmCompletion(id);
        assertEq(usdc.balanceOf(address(registry)), stakes, "settlement never touches stake");
        assertEq(registry.getProvider(alice).stake, MIN_STAKE);
    }

    function test_ManyProvidersManyRequests_AccountingExact() public {
        uint256[6] memory ids;
        for (uint256 i = 0; i < 6; ++i) {
            ids[i] = _create(i % 2 == 0 ? buyer : buyer2, address(0), uint128(10e6 + i * 1e6));
            vm.prank(i % 2 == 0 ? alice : bob);
            market.acceptRequest(ids[i]);
        }
        assertEq(_activeJobs(alice), 3);
        assertEq(_activeJobs(bob), 3);
        // Mix of outcomes
        for (uint256 i = 0; i < 6; ++i) {
            address p = i % 2 == 0 ? alice : bob;
            address b = i % 2 == 0 ? buyer : buyer2;
            if (i < 3) {
                vm.startPrank(p);
                market.startService(ids[i]);
                market.submitProof(ids[i], _proof(ids[i]));
                vm.stopPrank();
                vm.prank(b);
                market.confirmCompletion(ids[i]);
            } else {
                vm.prank(b);
                market.openDispute(ids[i], REASON);
                vm.prank(verifier);
                market.resolveDispute(ids[i], ClinovaTypes.Resolution.REFUND_NO_FAULT);
            }
        }
        assertEq(_activeJobs(alice), 0);
        assertEq(_activeJobs(bob), 0);
        assertEq(escrow.credit(alice), 10e6 + 12e6);
        assertEq(escrow.credit(bob), 11e6);
        assertEq(escrow.credit(buyer2), 13e6 + 15e6);
        assertEq(escrow.credit(buyer), 14e6);
        assertEq(escrow.totalLocked(), 0);
        _assertEscrowExact(0);
    }

    // ------------------------------------------------------------------
    // Phase 4: proof + reputation flows
    // ------------------------------------------------------------------

    function _expectState(
        uint256 id,
        ClinovaTypes.Status st,
        ClinovaTypes.EscrowState es,
        uint32 jobs,
        ClinovaTypes.ProofStatus ps
    ) internal view {
        assertEq(uint8(_status(id)), uint8(st), "marketplace status");
        assertEq(uint8(_escrowState(id)), uint8(es), "escrow state");
        assertEq(_activeJobs(alice), jobs, "provider activeJobs");
        assertEq(uint8(pos.proofStatus(id)), uint8(ps), "proof status");
    }

    /// register -> verify -> activate -> create/fund -> accept -> start -> proof -> approve -> settle -> reputation
    function test_Phase4_FullFlow_ApprovedProofSettlesAndUpdatesReputation() public {
        _registerProvider(dave);
        vm.prank(verifier);
        registry.verifyProvider(dave);
        vm.prank(dave);
        registry.activate();
        uint256 id = _open();
        vm.startPrank(dave);
        market.acceptRequest(id);
        market.startService(id);
        market.submitProof(id, keccak256("dave-evidence-commitment"));
        vm.stopPrank();
        vm.prank(verifier);
        market.approveProof(id);

        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.SETTLED));
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.APPROVED));
        ClinovaTypes.Reputation memory r = rep.getReputation(dave);
        assertEq(r.completedJobs, 1);
        assertEq(r.successfulJobs, 1);
        assertEq(r.failedJobs, 0);
        vm.prank(dave);
        escrow.withdraw();
        assertEq(usdc.balanceOf(dave), PRICE);
    }

    /// submit proof -> reject -> funds can never settle to the provider
    function test_Phase4_RejectedProofNeverSettles() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        vm.prank(buyer);
        vm.expectRevert();
        market.confirmCompletion(id);
        vm.prank(verifier);
        vm.expectRevert();
        market.approveProof(id);
        vm.prank(verifier);
        vm.expectRevert();
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
        assertEq(escrow.credit(alice), 0);
        assertEq(escrow.credit(buyer), PRICE);
        ClinovaTypes.Reputation memory r = rep.getReputation(alice);
        assertEq(r.failedJobs, 0, "verifier found no fault");
        assertEq(r.disputes, 1);
    }

    /// submit proof -> buyer disputes -> each resolution -> financial + reputation outcome
    function test_Phase4_ProofDisputeResolutions() public {
        uint256 a = _disputedFromCompleted(alice);
        uint256 b = _disputedFromCompleted(alice);
        uint256 c = _disputedFromCompleted(alice);
        vm.startPrank(verifier);
        market.resolveDispute(a, ClinovaTypes.Resolution.PROVIDER_WINS);
        market.resolveDispute(b, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        market.resolveDispute(c, ClinovaTypes.Resolution.REFUND_NO_FAULT);
        vm.stopPrank();
        assertEq(escrow.credit(alice), PRICE);
        assertEq(escrow.credit(buyer), 2 * PRICE);
        assertEq(uint8(pos.proofStatus(a)), uint8(ClinovaTypes.ProofStatus.APPROVED));
        assertEq(uint8(pos.proofStatus(b)), uint8(ClinovaTypes.ProofStatus.REJECTED));
        assertEq(uint8(pos.proofStatus(c)), uint8(ClinovaTypes.ProofStatus.REJECTED));
        ClinovaTypes.Reputation memory r = rep.getReputation(alice);
        assertEq(r.completedJobs, 3);
        assertEq(r.successfulJobs, 1);
        assertEq(r.failedJobs, 1, "only the PROVIDER_FAULT resolution counts as failure");
        assertEq(r.disputes, 3);
        assertEq(_activeJobs(alice), 0);
    }

    /// The proof/review path matrix: every path reaches a defined state; none locks escrow.
    function test_Phase4_PathMatrix() public {
        // 1. proof submitted -> verifier approves
        uint256 p1 = _completed(alice);
        vm.prank(verifier);
        market.approveProof(p1);
        _expectState(
            p1, ClinovaTypes.Status.SETTLED, ClinovaTypes.EscrowState.RELEASED, 0, ClinovaTypes.ProofStatus.APPROVED
        );

        // 2. proof submitted -> verifier rejects (funds stay locked pending fault decision / timeout)
        uint256 p2 = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(p2, REASON);
        _expectState(
            p2, ClinovaTypes.Status.DISPUTED, ClinovaTypes.EscrowState.FUNDED, 1, ClinovaTypes.ProofStatus.REJECTED
        );

        // 3. proof submitted -> buyer disputes
        uint256 p3 = _completed(alice);
        vm.prank(buyer);
        market.openDispute(p3, REASON);
        _expectState(
            p3, ClinovaTypes.Status.DISPUTED, ClinovaTypes.EscrowState.FUNDED, 2, ClinovaTypes.ProofStatus.SUBMITTED
        );

        // 4. proof submitted -> verifier does nothing -> closed unreviewed after the review window
        uint256 p4 = _completed(alice);
        // 5. no proof submitted -> service deadline passes
        uint256 p5 = _accepted(alice);
        assertEq(_activeJobs(alice), 4);

        vm.warp(_req(p4).reviewDeadline + 1);
        market.closeUnreviewed(p4);
        _expectState(
            p4, ClinovaTypes.Status.REFUNDED, ClinovaTypes.EscrowState.REFUNDED, 3, ClinovaTypes.ProofStatus.UNRESOLVED
        );

        vm.warp(_req(p5).serviceDeadline + 1);
        vm.prank(buyer);
        market.expireRequest(p5);
        _expectState(
            p5, ClinovaTypes.Status.EXPIRED, ClinovaTypes.EscrowState.REFUNDED, 2, ClinovaTypes.ProofStatus.NONE
        );

        // 6. proof rejected -> dispute timeout (and 3 buyer dispute -> timeout)
        vm.warp(_req(p2).disputeDeadline + 1);
        market.resolveDisputeByTimeout(p2);
        _expectState(
            p2, ClinovaTypes.Status.REFUNDED, ClinovaTypes.EscrowState.REFUNDED, 1, ClinovaTypes.ProofStatus.REJECTED
        );
        market.resolveDisputeByTimeout(p3);
        _expectState(
            p3, ClinovaTypes.Status.REFUNDED, ClinovaTypes.EscrowState.REFUNDED, 0, ClinovaTypes.ProofStatus.UNRESOLVED
        );

        assertEq(escrow.totalLocked(), 0, "nothing left locked");
        assertEq(escrow.credit(alice), PRICE, "only the approved path paid");
        assertEq(escrow.credit(buyer), 4 * PRICE);
        ClinovaTypes.Reputation memory r = rep.getReputation(alice);
        assertEq(r.completedJobs, 4);
        assertEq(r.successfulJobs, 1);
        assertEq(r.failedJobs, 1, "only the missed deadline");
        assertEq(r.disputes, 2);
    }
}
