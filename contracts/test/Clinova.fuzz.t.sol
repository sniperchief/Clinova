// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaBase} from "./ClinovaBase.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";

contract ClinovaFuzzTest is ClinovaBase {
    // ------------------------------------------------------------------
    // Prices / deadlines / ids / callers
    // ------------------------------------------------------------------

    function testFuzz_PriceAndDeadlines(uint128 price, uint64 acceptOffset, uint64 serviceOffset) public {
        price = uint128(bound(price, 0, 1e15));
        acceptOffset = uint64(bound(acceptOffset, 0, 10 days));
        serviceOffset = uint64(bound(serviceOffset, 0, 40 days));
        uint64 a = uint64(block.timestamp) + acceptOffset;
        uint64 s = a + serviceOffset;
        bool priceOk = price >= MIN_PRICE;
        bool aOk = acceptOffset >= 1 hours && acceptOffset <= 7 days;
        bool sOk = serviceOffset >= 6 hours && serviceOffset <= 30 days;
        _fundBuyer(buyer, price);

        vm.prank(buyer);
        if (!priceOk) {
            vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.PriceTooLow.selector, price, MIN_PRICE));
            market.createRequest(address(0), CBC, REGION, price, a, s);
            return;
        }
        if (!aOk || !sOk) {
            vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
            market.createRequest(address(0), CBC, REGION, price, a, s);
            return;
        }
        uint256 id = market.createRequest(address(0), CBC, REGION, price, a, s);
        assertEq(escrow.getDeposit(id).amount, price);

        vm.startPrank(alice);
        market.acceptRequest(id);
        market.startService(id);
        market.submitProof(id, _proof(id));
        vm.stopPrank();
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.prank(alice);
        assertEq(escrow.withdraw(), price, "provider paid exactly the fixed price");
        _assertEscrowExact(0);
    }

    function testFuzz_NonexistentIdsRevert(uint256 id) public {
        _open();
        vm.assume(id == 0 || id >= market.nextRequestId());
        bytes memory err =
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.NONE);
        vm.prank(alice);
        vm.expectRevert(err);
        market.acceptRequest(id);
        vm.prank(buyer);
        vm.expectRevert(err);
        market.cancelRequest(id);
        vm.expectRevert(err);
        market.expireRequest(id);
        vm.expectRevert(err);
        market.closeUnreviewed(id);
        vm.expectRevert(err);
        market.resolveDisputeByTimeout(id);
    }

    function testFuzz_ArbitraryAddressCannotAccept(address p) public {
        vm.assume(p != alice && p != bob && p != buyer);
        uint256 id = _open();
        vm.prank(p);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, p, CBC));
        market.acceptRequest(id);
        assertEq(_req(id).provider, address(0));
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.OPEN));
    }

    function testFuzz_NonPartyCannotActOnRequest(address caller) public {
        vm.assume(caller != buyer && caller != alice);
        uint256 id = _completed(alice);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotBuyer.selector, id));
        market.confirmCompletion(id);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotBuyer.selector, id));
        market.openDispute(id, REASON);
        vm.stopPrank();
        uint256 acc = _accepted(alice);
        vm.warp(_req(acc).serviceDeadline + 1);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotParty.selector, acc));
        market.expireRequest(acc);
    }

    function testFuzz_ExpiryTiming(uint64 elapsed) public {
        uint256 id = _accepted(alice);
        uint64 s = _req(id).serviceDeadline;
        elapsed = uint64(bound(elapsed, 0, 10 days));
        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.prank(buyer);
        if (vm.getBlockTimestamp() <= s) {
            vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, s));
            market.expireRequest(id);
        } else {
            market.expireRequest(id);
            assertEq(escrow.credit(buyer), PRICE);
            assertEq(_activeJobs(alice), 0);
        }
    }

    // ------------------------------------------------------------------
    // Every terminal path: exactly one party credited, exactly once
    // ------------------------------------------------------------------

    function testFuzz_TerminalOutcomeConservesFunds(uint8 path, uint128 price) public {
        price = uint128(bound(price, MIN_PRICE, 1e12));
        path = uint8(bound(path, 0, 10));
        uint256 id = _create(buyer, address(0), price);
        bool providerPaid;
        if (path == 0) {
            vm.prank(buyer);
            market.cancelRequest(id);
        } else if (path == 1) {
            vm.warp(_req(id).acceptDeadline + 1);
            market.expireRequest(id);
        } else {
            vm.prank(alice);
            market.acceptRequest(id);
            if (path == 2) {
                vm.warp(_req(id).serviceDeadline + 1);
                vm.prank(buyer);
                market.expireRequest(id);
            } else if (path == 3) {
                vm.prank(buyer);
                market.openDispute(id, REASON);
                vm.prank(verifier);
                market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
            } else {
                vm.startPrank(alice);
                market.startService(id);
                market.submitProof(id, _proof(id));
                vm.stopPrank();
                providerPaid = path <= 5;
                if (path == 4) {
                    vm.prank(buyer);
                    market.confirmCompletion(id);
                } else if (path == 5) {
                    vm.prank(verifier);
                    market.approveProof(id);
                } else if (path == 6) {
                    // Phase 4: nobody reviewed -> no-fault refund, never a payment.
                    vm.warp(_req(id).reviewDeadline + 1);
                    market.closeUnreviewed(id);
                } else if (path == 7) {
                    vm.prank(buyer);
                    market.openDispute(id, REASON);
                    vm.prank(verifier);
                    market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
                    providerPaid = true;
                } else if (path == 8) {
                    vm.prank(verifier);
                    market.rejectProof(id, REASON);
                    vm.prank(verifier);
                    market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
                } else {
                    vm.prank(buyer);
                    market.openDispute(id, REASON);
                    vm.warp(_req(id).disputeDeadline + 1);
                    market.resolveDisputeByTimeout(id);
                }
            }
        }
        assertTrue(ClinovaTypes.isTerminal(_status(id)));
        assertEq(escrow.credit(alice) + escrow.credit(buyer), price, "exactly the escrowed amount is credited");
        assertEq(escrow.credit(providerPaid ? alice : buyer), price);
        assertEq(escrow.credit(providerPaid ? buyer : alice), 0);
        assertEq(
            uint8(_escrowState(id)),
            uint8(providerPaid ? ClinovaTypes.EscrowState.RELEASED : ClinovaTypes.EscrowState.REFUNDED)
        );
        assertEq(_activeJobs(alice), 0);
        assertEq(escrow.totalLocked(), 0);
        _assertEscrowExact(0);

        // Proof and reputation agree with the outcome.
        ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
        if (providerPaid) {
            assertTrue(ps == ClinovaTypes.ProofStatus.APPROVED || ps == ClinovaTypes.ProofStatus.BUYER_ACCEPTED);
        } else {
            assertTrue(ps != ClinovaTypes.ProofStatus.APPROVED && ps != ClinovaTypes.ProofStatus.BUYER_ACCEPTED);
            assertTrue(ps != ClinovaTypes.ProofStatus.SUBMITTED, "terminal request leaves no open proof");
        }
        ClinovaTypes.Reputation memory r = rep.getReputation(alice);
        bool accepted = path >= 2;
        assertEq(rep.outcomeRecorded(id), accepted);
        assertEq(r.successfulJobs, providerPaid ? 1 : 0);
        assertEq(r.completedJobs, path >= 4 ? 1 : 0);
        assertEq(r.failedJobs, (path == 2 || path == 3) ? 1 : 0, "fault only for missed deadline / PROVIDER_FAULT");
        assertEq(r.disputes, (path == 3 || path >= 7) ? 1 : 0);
    }

    // ------------------------------------------------------------------
    // Arbitrary call ordering: random actions, random actors, checks after every step
    // ------------------------------------------------------------------

    function testFuzz_RandomCallSequence(uint256 seed) public {
        address[6] memory actors = [buyer, buyer2, alice, bob, verifier, attacker];
        uint256 n = 3;
        for (uint256 i = 0; i < n; ++i) {
            _create(i == 1 ? buyer2 : buyer, address(0), uint128(5e6 + i * 1e6));
        }
        for (uint256 step = 0; step < 40; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 id = 1 + (r >> 8) % n;
            uint256 action = (r >> 16) % 14;
            // 75%: the actor the action's role requires; 25%: anyone (exercises authorization failures).
            address who = (r >> 32) % 4 == 0 ? actors[r % 6] : _roleActor(action, id, r);
            if (action == 13) {
                vm.warp(block.timestamp + ((r >> 24) % 5 days));
                continue;
            }
            bytes memory data;
            if (action == 0) data = abi.encodeCall(market.acceptRequest, (id));
            else if (action == 1) data = abi.encodeCall(market.startService, (id));
            else if (action == 2) data = abi.encodeCall(market.submitProof, (id, keccak256(abi.encode(seed, step % 6)))); // frequent replays
            else if (action == 3) data = abi.encodeCall(market.confirmCompletion, (id));
            else if (action == 4) data = abi.encodeCall(market.approveProof, (id));
            else if (action == 5) data = abi.encodeCall(market.rejectProof, (id, REASON));
            else if (action == 6) data = abi.encodeCall(market.openDispute, (id, REASON));
            else if (action == 7) data = abi.encodeCall(market.resolveDispute, (id, ClinovaTypes.Resolution(r % 3)));
            else if (action == 8) data = abi.encodeCall(market.cancelRequest, (id));
            else if (action == 9) data = abi.encodeCall(market.expireRequest, (id));
            else if (action == 10) data = abi.encodeCall(market.closeUnreviewed, (id));
            else if (action == 11) data = abi.encodeCall(market.resolveDisputeByTimeout, (id));
            else data = abi.encodeWithSignature("withdraw()");
            address target = action == 12 ? address(escrow) : address(market);
            vm.prank(who);
            (bool ok,) = target.call(data);
            ok; // failures are expected for most random calls
            _checkSystem(n);
        }
    }

    function _roleActor(uint256 action, uint256 id, uint256 r) internal view returns (address) {
        ClinovaTypes.ServiceRequest memory req = _req(id);
        if (action == 0) return (r >> 40) % 2 == 0 ? alice : bob;
        if (action == 1 || action == 2) return req.provider;
        if (action == 4 || action == 5 || action == 7) return verifier;
        if (action == 6 || action == 9) return (r >> 40) % 2 == 0 ? req.buyer : req.provider;
        if (action == 12) return [buyer, buyer2, alice, bob][(r >> 40) % 4];
        return req.buyer;
    }

    function _checkSystem(uint256 n) internal view {
        uint256 locked;
        uint32 aliceJobs;
        uint32 bobJobs;
        for (uint256 id = 1; id <= n; ++id) {
            ClinovaTypes.ServiceRequest memory r = _req(id);
            ClinovaTypes.Deposit memory d = escrow.getDeposit(id);
            assertEq(d.amount, r.price);
            bool terminal = ClinovaTypes.isTerminal(r.status);
            if (!terminal) {
                locked += r.price;
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.FUNDED));
            } else if (r.status == ClinovaTypes.Status.SETTLED) {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.RELEASED));
            } else {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.REFUNDED));
            }
            if (
                r.status != ClinovaTypes.Status.OPEN && r.status != ClinovaTypes.Status.CANCELLED
                    && r.provider != address(0)
            ) {
                assertEq(d.payee, r.provider, "escrow payee is the accepting provider");
            }
            bool jobOpen = !terminal && r.status != ClinovaTypes.Status.OPEN;
            assertEq(registry.getJob(id).status == ClinovaTypes.JobStatus.OPEN, jobOpen);
            if (jobOpen && r.provider == alice) aliceJobs++;
            if (jobOpen && r.provider == bob) bobJobs++;
        }
        assertEq(escrow.totalLocked(), locked);
        assertEq(_activeJobs(alice), aliceJobs);
        assertEq(_activeJobs(bob), bobJobs);
        assertEq(
            escrow.totalCredited(),
            escrow.credit(buyer) + escrow.credit(buyer2) + escrow.credit(alice) + escrow.credit(bob)
        );
        assertEq(escrow.credit(verifier) + escrow.credit(attacker), 0);
        _assertEscrowExact(0);
        uint256 successes;
        for (uint256 id = 1; id <= n; ++id) {
            ClinovaTypes.ServiceRequest memory r = _req(id);
            ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
            if (ps != ClinovaTypes.ProofStatus.NONE) assertEq(pos.getProof(id).provider, r.provider);
            if (r.status == ClinovaTypes.Status.SETTLED) {
                successes++;
                assertTrue(ps == ClinovaTypes.ProofStatus.APPROVED || ps == ClinovaTypes.ProofStatus.BUYER_ACCEPTED);
            }
            if (ClinovaTypes.isTerminal(r.status)) assertTrue(ps != ClinovaTypes.ProofStatus.SUBMITTED);
            assertEq(rep.outcomeRecorded(id), registry.getJob(id).status == ClinovaTypes.JobStatus.CLOSED);
        }
        assertEq(rep.getReputation(alice).successfulJobs + rep.getReputation(bob).successfulJobs, successes);
    }
}
