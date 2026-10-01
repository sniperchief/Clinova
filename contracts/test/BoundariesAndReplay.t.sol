// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaBase} from "./ClinovaBase.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ProofOfService} from "../src/ProofOfService.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IProofOfService} from "../src/interfaces/IProofOfService.sol";

/// @notice Phase 5 §14 (deadline/timestamp boundaries) and §15 (replay / hash binding).
/// @dev Convention under test: an action "before X" is allowed while now <= X; an exit "after X" only when now > X.
///      The single exception is unbonding (now >= unstakeAvailableAt), which is documented in the spec and checked
///      here so that a change in either direction is noticed.
contract BoundariesAndReplayTest is ClinovaBase {
    function _deadlinePassed(uint64 d) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, d);
    }

    function _deadlineNotPassed(uint64 d) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, d);
    }

    // ------------------------------------------------------------------
    // Creation windows (exact bounds)
    // ------------------------------------------------------------------

    function test_Boundary_CreationWindows() public {
        uint64 t = uint64(vm.getBlockTimestamp());
        uint64 minA = t + 1 hours;
        uint64 maxA = t + 7 days;
        vm.startPrank(buyer);
        market.createRequest(address(0), CBC, REGION, PRICE, minA, minA + 6 hours); // both minimums
        market.createRequest(address(0), CBC, REGION, PRICE, maxA, maxA + 30 days); // both maximums
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, minA - 1, minA + 6 hours);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, maxA + 1, maxA + 1 + 6 hours);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, minA, minA + 6 hours - 1);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, minA, minA + 30 days + 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // acceptDeadline
    // ------------------------------------------------------------------

    function test_Boundary_AcceptDeadline() public {
        uint256 id = _open();
        uint64 d = _req(id).acceptDeadline;
        uint256 snap = vm.snapshotState();
        vm.warp(d - 1);
        vm.prank(alice);
        market.acceptRequest(id);
        vm.revertToState(snap);

        vm.warp(d); // exactly at the deadline: accept allowed, expiry not yet
        vm.expectRevert(_deadlineNotPassed(d));
        market.expireRequest(id);
        snap = vm.snapshotState();
        vm.prank(alice);
        market.acceptRequest(id);
        vm.revertToState(snap);

        vm.warp(d + 1); // one second after: accept refused, expiry open to anyone
        vm.prank(alice);
        vm.expectRevert(_deadlinePassed(d));
        market.acceptRequest(id);
        vm.prank(attacker);
        market.expireRequest(id);
    }

    // ------------------------------------------------------------------
    // serviceDeadline (start, proof, dispute vs. expiry)
    // ------------------------------------------------------------------

    function test_Boundary_ServiceDeadline() public {
        uint256 acc = _accepted(alice);
        uint256 svc = _inService(alice);
        uint256 disp = _inService(alice);
        uint64 d = _req(acc).serviceDeadline;
        assertEq(_req(svc).serviceDeadline, d);

        vm.warp(d); // last second for every provider action and for in-flight disputes
        vm.expectRevert(_deadlineNotPassed(d));
        vm.prank(buyer);
        market.expireRequest(acc);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        market.startService(acc);
        vm.prank(alice);
        market.submitProof(svc, _proof(svc));
        vm.prank(buyer);
        market.openDispute(disp, REASON);
        vm.revertToState(snap);

        vm.warp(d + 1);
        vm.startPrank(alice);
        vm.expectRevert(_deadlinePassed(d));
        market.startService(acc);
        vm.expectRevert(_deadlinePassed(d));
        market.submitProof(svc, _proof(svc));
        vm.expectRevert(_deadlinePassed(d));
        market.openDispute(disp, REASON);
        market.expireRequest(acc); // the provider may close its own missed job
        vm.stopPrank();
        vm.prank(buyer);
        market.expireRequest(svc);
    }

    /// Proof into a dispute uses serviceDeadline too.
    function test_Boundary_ProofIntoDisputeDeadline() public {
        uint256 id = _accepted(alice);
        vm.prank(buyer);
        market.openDispute(id, REASON);
        uint64 d = _req(id).serviceDeadline;
        vm.warp(d + 1);
        vm.prank(alice);
        vm.expectRevert(_deadlinePassed(d));
        market.submitProof(id, _proof(id));
        vm.warp(d);
        vm.prank(alice);
        market.submitProof(id, _proof(id));
    }

    // ------------------------------------------------------------------
    // reviewDeadline
    // ------------------------------------------------------------------

    function test_Boundary_ReviewDeadline() public {
        uint256 id = _completed(alice);
        uint64 d = _req(id).reviewDeadline;
        assertEq(d, uint64(vm.getBlockTimestamp()) + REVIEW);

        vm.warp(d);
        vm.expectRevert(_deadlineNotPassed(d));
        market.closeUnreviewed(id);
        uint256 snap = vm.snapshotState();
        vm.prank(buyer);
        market.openDispute(id, REASON); // last second for a buyer dispute
        vm.revertToState(snap);

        vm.warp(d + 1);
        vm.prank(buyer);
        vm.expectRevert(_deadlinePassed(d));
        market.openDispute(id, REASON);
        snap = vm.snapshotState();
        vm.prank(verifier);
        market.approveProof(id); // review is still possible until someone closes it
        vm.revertToState(snap);
        snap = vm.snapshotState();
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.revertToState(snap);
        market.closeUnreviewed(id);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.REFUNDED)
        );
        market.approveProof(id);
    }

    // ------------------------------------------------------------------
    // disputeDeadline
    // ------------------------------------------------------------------

    function test_Boundary_DisputeDeadline() public {
        uint256 id = _disputedFromCompleted(alice);
        uint64 d = _req(id).disputeDeadline;
        assertEq(d, uint64(vm.getBlockTimestamp()) + DISPUTE);
        vm.warp(d);
        vm.expectRevert(_deadlineNotPassed(d));
        market.resolveDisputeByTimeout(id);
        vm.warp(d + 1);
        uint256 snap = vm.snapshotState();
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS); // late resolution until timeout executes
        vm.revertToState(snap);
        market.resolveDisputeByTimeout(id);
    }

    // ------------------------------------------------------------------
    // Unbonding (inclusive by design)
    // ------------------------------------------------------------------

    function test_Boundary_Unbonding() public {
        vm.prank(alice);
        registry.requestUnstake();
        uint64 at = registry.getProvider(alice).unstakeAvailableAt;
        assertEq(at, uint64(vm.getBlockTimestamp()) + UNBONDING);
        vm.warp(at - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.UnstakeNotReady.selector, at));
        registry.withdrawStake();
        vm.warp(at); // inclusive: spec §2 "now >= unstakeAvailableAt"
        vm.prank(alice);
        registry.withdrawStake();
    }

    /// Changing the admin parameters never moves an existing deadline (snapshots).
    function test_Boundary_SnapshotsSurviveParameterChanges() public {
        vm.prank(alice);
        registry.requestUnstake();
        uint64 at = registry.getProvider(alice).unstakeAvailableAt;
        uint256 comp = _completed(bob);
        uint64 rd = _req(comp).reviewDeadline;
        vm.startPrank(admin);
        registry.setUnbondingPeriod(30 days);
        market.setReviewPeriod(14 days);
        market.setDisputePeriod(60 days);
        vm.stopPrank();
        assertEq(registry.getProvider(alice).unstakeAvailableAt, at);
        assertEq(_req(comp).reviewDeadline, rd);
        vm.prank(buyer);
        market.openDispute(comp, REASON);
        assertEq(
            _req(comp).disputeDeadline,
            uint64(vm.getBlockTimestamp()) + DISPUTE,
            "dispute period snapshotted at creation"
        );
    }

    /// block.number plays no role: moving it arbitrarily changes nothing (Arbitrum returns an L1 estimate).
    function test_BlockNumberIsIrrelevant() public {
        uint256 id = _accepted(alice);
        vm.roll(1);
        vm.prank(alice);
        market.startService(id);
        vm.roll(type(uint64).max);
        vm.prank(alice);
        market.submitProof(id, _proof(id));
        vm.roll(2);
        vm.prank(buyer);
        market.confirmCompletion(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.SETTLED));
    }

    // ------------------------------------------------------------------
    // §15 Replay / hash binding
    // ------------------------------------------------------------------

    function test_Replay_AcrossRequestsSameProvider() public {
        bytes32 c = keccak256("bundle");
        uint256 a = _inService(alice);
        uint256 b = _inService(alice);
        vm.prank(alice);
        market.submitProof(a, c);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.EvidenceAlreadyUsed.selector, alice, c));
        market.submitProof(b, c);
        // also blocked as dispute evidence
        uint256 d = _accepted(alice);
        vm.prank(buyer);
        market.openDispute(d, REASON);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.EvidenceAlreadyUsed.selector, alice, c));
        market.submitProof(d, c);
    }

    function test_Replay_AcrossChains() public {
        uint256 id = _completed(alice);
        ClinovaTypes.ServiceProof memory p = pos.getProof(id);
        assertEq(p.proofHash, pos.computeProofHash(id, alice, p.evidenceCommitment));
        uint256 chain = vm.getChainId();
        vm.chainId(421614);
        bytes32 onSepolia = pos.computeProofHash(id, alice, p.evidenceCommitment);
        vm.chainId(42161);
        bytes32 onOne = pos.computeProofHash(id, alice, p.evidenceCommitment);
        vm.chainId(chain);
        assertTrue(onSepolia != onOne && onSepolia != p.proofHash && onOne != p.proofHash, "chain id is bound");
    }

    /// Two deployments issue the same request ids. The proofHash differs (bound to the PoS address), but the raw
    /// evidence commitment is only single-use per deployment: the offchain verifier must check that the opened
    /// evidence bundle names this chain, PoS address, request id and provider (documented, spec §5).
    function test_Replay_AcrossDeployments() public {
        bytes32 c = keccak256("bundle-x");
        uint256 id1 = _inService(alice);
        vm.prank(alice);
        market.submitProof(id1, c);
        bytes32 h1 = pos.getProof(id1).proofHash;

        Deploy d = new Deploy();
        Deploy.Deployment memory dep2 = d.deploy(_config(address(usdc)), address(d));
        ProofOfService pos2 = dep2.proofOfService;
        assertEq(dep2.marketplace.nextRequestId(), 1, "request ids restart per deployment");
        bytes32 h2 = pos2.computeProofHash(id1, alice, c);
        assertTrue(h1 != h2, "deployment address is bound");
        assertFalse(pos2.evidenceUsed(alice, c), "commitment single-use is per deployment");
    }

    function test_Replay_DomainIsFixed() public view {
        assertEq(pos.PROOF_DOMAIN(), keccak256("CLINOVA_PROOF_V1"));
        bytes32 expected = keccak256(
            abi.encode(keccak256("CLINOVA_PROOF_V1"), block.chainid, address(pos), uint256(7), alice, bytes32("c"))
        );
        assertEq(pos.computeProofHash(7, alice, bytes32("c")), expected);
    }

    /// Distinct (request, provider, commitment) tuples never produce the same proofHash.
    function testFuzz_ProofHashInjective(uint256 id1, uint256 id2, address p1, address p2, bytes32 c1, bytes32 c2)
        public
        view
    {
        vm.assume(id1 != id2 || p1 != p2 || c1 != c2);
        assertTrue(pos.computeProofHash(id1, p1, c1) != pos.computeProofHash(id2, p2, c2));
    }

    function test_RequestIds_SequentialNeverReused_ZeroInvalid() public {
        assertEq(market.nextRequestId(), 1);
        uint256 a = _open();
        vm.prank(buyer);
        market.cancelRequest(a);
        uint256 b = _open();
        assertEq(b, a + 1, "a cancelled id is never reissued");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, 0, ClinovaTypes.Status.NONE));
        market.acceptRequest(0);
    }
}
