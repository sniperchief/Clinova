// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ClinovaEscrow} from "../src/ClinovaEscrow.sol";
import {ServiceMarketplace} from "../src/ServiceMarketplace.sol";
import {ProofOfService} from "../src/ProofOfService.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {ClinovaBase} from "./ClinovaBase.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

/// @notice Drives the full system through random but deliberately *reachable* lifecycle paths.
/// @dev Each action prefers a request in the state where it can succeed (falls back to a random one), so
///      deep paths (accept -> start -> proof -> dispute -> resolve/timeout -> withdraw) are actually exercised.
///      `_sync()` observes every request after every action and records outcomes independently of which
///      action ran, so unexpected transitions (including from attacker calls) are caught too.
contract MarketHandler is Test {
    ServiceMarketplace public immutable market;
    ClinovaEscrow public immutable escrow;
    ProviderRegistry public immutable registry;
    ProofOfService public immutable pos;
    ReputationRegistry public immutable rep;
    MockUSDC public immutable usdc;
    address public immutable verifier;
    address public immutable pauser;
    address public immutable attacker;

    address[3] public buyers;
    address[3] public providers; // all eligible
    address public immutable unverified;

    uint256[] public ids;
    uint256 public constant MAX_REQUESTS = 30;
    uint256 internal proofNonce;

    // ghosts
    mapping(uint256 => bool) public outcomeRecorded;
    mapping(uint256 => ClinovaTypes.Status) public recordedTerminal;
    mapping(uint256 => address) public firstProvider;
    mapping(address => uint256) public ghostCredited;
    mapping(address => uint256) public ghostWithdrawn;
    uint256 public ghostDonations;
    uint256 public ghostMinted;
    bool public violation;
    string public violationReason;
    mapping(bytes32 => uint256) public successes;
    // proof / reputation ghosts (set only by successful handler actions, never read back from the modules)
    mapping(uint256 => address) public acceptedBy;
    mapping(uint256 => bool) public ghostProofSubmitted;
    mapping(uint256 => bool) public ghostDisputed;
    mapping(uint256 => bool) public ghostFault;
    mapping(uint256 => ClinovaTypes.ProofStatus) public ghostProofFinal;
    mapping(address => uint64) public ghostCompleted;
    mapping(address => uint64) public ghostSuccessful;
    mapping(address => uint64) public ghostFailed;
    mapping(address => uint64) public ghostDisputes;

    constructor(
        ServiceMarketplace m,
        address[3] memory buyers_,
        address[3] memory providers_,
        address unverified_,
        address verifier_,
        address pauser_,
        uint256 initialMinted
    ) {
        market = m;
        escrow = ClinovaEscrow(address(m.escrow()));
        registry = ProviderRegistry(address(m.registry()));
        pos = ProofOfService(address(m.proofOfService()));
        rep = ReputationRegistry(address(m.reputation()));
        usdc = MockUSDC(address(m.usdc()));
        buyers = buyers_;
        providers = providers_;
        unverified = unverified_;
        verifier = verifier_;
        pauser = pauser_;
        attacker = makeAddr("inv-attacker");
        ghostMinted = initialMinted;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    // ------------------------------------------------------------------
    // Selection helpers
    // ------------------------------------------------------------------

    function _pick(uint256 seed, ClinovaTypes.Status want) internal view returns (uint256 id, bool found) {
        uint256 n = ids.length;
        if (n == 0) return (0, false);
        for (uint256 i = 0; i < n; ++i) {
            uint256 candidate = ids[(seed % n + i) % n];
            if (market.getRequest(candidate).status == want) return (candidate, true);
        }
        return (ids[seed % n], false);
    }

    function _pick2(uint256 seed, ClinovaTypes.Status a, ClinovaTypes.Status b) internal view returns (uint256) {
        (uint256 id, bool found) = _pick(seed, a);
        if (found) return id;
        (id,) = _pick(seed >> 1, b);
        return id;
    }

    function _call(address who, address target, bytes memory data, bytes32 key) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = target.call(data);
        if (ok) successes[key]++;
        _sync();
    }

    /// @dev Record every newly-terminal request exactly once; detect illegal changes.
    function _sync() internal {
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            if (firstProvider[id] == address(0) && r.provider != address(0) && r.status != ClinovaTypes.Status.OPEN) {
                firstProvider[id] = r.provider;
            }
            if (firstProvider[id] != address(0) && r.provider != firstProvider[id]) _fail("provider changed");
            ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
            if (ps != ClinovaTypes.ProofStatus.NONE && ps != ClinovaTypes.ProofStatus.SUBMITTED) {
                if (ghostProofFinal[id] == ClinovaTypes.ProofStatus.NONE) ghostProofFinal[id] = ps;
                else if (ghostProofFinal[id] != ps) _fail("final proof status changed");
            }
            if (outcomeRecorded[id]) {
                if (r.status != recordedTerminal[id]) _fail("terminal status changed");
                continue;
            }
            if (!ClinovaTypes.isTerminal(r.status)) continue;
            outcomeRecorded[id] = true;
            recordedTerminal[id] = r.status;
            address beneficiary = r.status == ClinovaTypes.Status.SETTLED ? r.provider : r.buyer;
            ghostCredited[beneficiary] += r.price;
            // Expected reputation, from the handler's own record of what happened.
            address p = acceptedBy[id];
            if (p != address(0)) {
                if (ghostProofSubmitted[id]) ghostCompleted[p]++;
                if (r.status == ClinovaTypes.Status.SETTLED) ghostSuccessful[p]++;
                if (
                    r.status == ClinovaTypes.Status.EXPIRED
                        || (r.status == ClinovaTypes.Status.REFUNDED && ghostFault[id])
                ) {
                    ghostFailed[p]++;
                }
                if (ghostDisputed[id]) ghostDisputes[p]++;
            }
        }
    }

    function _fail(string memory reason) internal {
        if (!violation) violationReason = reason;
        violation = true;
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    function create(uint256 buyerSeed, uint256 directedSeed, uint128 price, uint64 aOff, uint64 sOff) external {
        if (ids.length >= MAX_REQUESTS) return;
        address b = buyers[buyerSeed % 3];
        price = uint128(bound(price, 1e6, 1_000e6));
        uint64 a = uint64(block.timestamp + bound(aOff, 1 hours, 7 days));
        uint64 s = uint64(a + bound(sOff, 6 hours, 30 days));
        address directed = directedSeed % 4 == 0 ? providers[directedSeed % 3] : address(0);
        usdc.mint(b, price);
        ghostMinted += price;
        vm.prank(b);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(b);
        try market.createRequest(directed, keccak256("LAB.CBC.V1"), keccak256("region"), price, a, s) returns (
            uint256 id
        ) {
            ids.push(id);
            successes["create"]++;
        } catch {}
        _sync();
    }

    function accept(uint256 reqSeed, uint256 provSeed) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.OPEN);
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        address p = provSeed % 8 == 0 ? unverified : (r.provider != address(0) ? r.provider : providers[provSeed % 3]);
        if (_call(p, address(market), abi.encodeCall(market.acceptRequest, (id)), "accept")) acceptedBy[id] = p;
    }

    function start(uint256 reqSeed) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.ACCEPTED);
        _call(market.getRequest(id).provider, address(market), abi.encodeCall(market.startService, (id)), "start");
    }

    function submitProof(uint256 reqSeed, bool preferDispute) external {
        uint256 id = preferDispute
            ? _pick2(reqSeed, ClinovaTypes.Status.DISPUTED, ClinovaTypes.Status.IN_SERVICE)
            : _pick2(reqSeed, ClinovaTypes.Status.IN_SERVICE, ClinovaTypes.Status.DISPUTED);
        bool intoDispute = market.getRequest(id).status == ClinovaTypes.Status.DISPUTED;
        // Occasionally replay an earlier commitment (must fail for the same provider).
        bytes32 h = reqSeed % 7 == 0 && proofNonce > 0
            ? keccak256(abi.encode("proof", proofNonce))
            : keccak256(abi.encode("proof", ++proofNonce));
        bytes32 key = intoDispute ? bytes32("proofIntoDispute") : bytes32("proof");
        if (_call(market.getRequest(id).provider, address(market), abi.encodeCall(market.submitProof, (id, h)), key)) {
            ghostProofSubmitted[id] = true;
        }
    }

    function confirm(uint256 reqSeed) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        _call(market.getRequest(id).buyer, address(market), abi.encodeCall(market.confirmCompletion, (id)), "confirm");
    }

    function approve(uint256 reqSeed) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        _call(verifier, address(market), abi.encodeCall(market.approveProof, (id)), "approve");
    }

    function reject(uint256 reqSeed) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        if (_call(verifier, address(market), abi.encodeCall(market.rejectProof, (id, keccak256("why"))), "reject")) {
            ghostDisputed[id] = true;
        }
    }

    function dispute(uint256 reqSeed, bool byProvider) external {
        uint256 id = _pick2(reqSeed, ClinovaTypes.Status.ACCEPTED, ClinovaTypes.Status.IN_SERVICE);
        if (reqSeed % 3 == 0) (id,) = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        address who = byProvider ? r.provider : r.buyer;
        if (_call(who, address(market), abi.encodeCall(market.openDispute, (id, keccak256("why"))), "dispute")) {
            ghostDisputed[id] = true;
        }
    }

    function resolve(uint256 reqSeed, uint8 res) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.DISPUTED);
        ClinovaTypes.Resolution resolution = ClinovaTypes.Resolution(res % 3);
        bool fault = resolution == ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT;
        bytes32 key = res % 3 == 0 ? bytes32("resolve_pw") : (fault ? bytes32("resolve_pf") : bytes32("resolve_nf"));
        // The fault flag must be known before _sync records the terminal outcome inside _call.
        if (fault) ghostFault[id] = true;
        bool ok = _call(verifier, address(market), abi.encodeCall(market.resolveDispute, (id, resolution)), key);
        if (fault && !ok) ghostFault[id] = false;
    }

    function cancel(uint256 reqSeed) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.OPEN);
        _call(market.getRequest(id).buyer, address(market), abi.encodeCall(market.cancelRequest, (id)), "cancel");
    }

    function expire(uint256 reqSeed, bool byProvider, bool warpPast) external {
        uint256 id = _pick2(reqSeed, ClinovaTypes.Status.ACCEPTED, ClinovaTypes.Status.IN_SERVICE);
        if (reqSeed % 3 == 0) (id,) = _pick(reqSeed, ClinovaTypes.Status.OPEN);
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        uint64 deadline = r.status == ClinovaTypes.Status.OPEN ? r.acceptDeadline : r.serviceDeadline;
        if (warpPast && block.timestamp <= deadline) vm.warp(uint256(deadline) + 1);
        address who = r.status == ClinovaTypes.Status.OPEN ? attacker : (byProvider ? r.provider : r.buyer);
        _call(who, address(market), abi.encodeCall(market.expireRequest, (id)), "expire");
    }

    function closeUnreviewed(uint256 reqSeed, bool warpPast) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        uint64 rd = market.getRequest(id).reviewDeadline;
        if (warpPast && block.timestamp <= rd) vm.warp(uint256(rd) + 1);
        _call(attacker, address(market), abi.encodeCall(market.closeUnreviewed, (id)), "closeUnreviewed");
    }

    function timeout(uint256 reqSeed, bool warpPast) external {
        (uint256 id,) = _pick(reqSeed, ClinovaTypes.Status.DISPUTED);
        uint64 dd = market.getRequest(id).disputeDeadline;
        if (warpPast && block.timestamp <= dd) vm.warp(uint256(dd) + 1);
        _call(attacker, address(market), abi.encodeCall(market.resolveDisputeByTimeout, (id)), "timeout");
    }

    function withdraw(uint256 seed) external {
        address who = seed % 2 == 0 ? buyers[seed % 3] : providers[seed % 3];
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        try escrow.withdraw() returns (uint256 amount) {
            successes["withdraw"]++;
            ghostWithdrawn[who] += amount;
            if (usdc.balanceOf(who) - before != amount) _fail("withdraw amount mismatch");
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
    }

    function togglePause() external {
        vm.startPrank(pauser);
        if (market.paused()) market.unpause();
        else market.pause();
        vm.stopPrank();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 5e6);
        usdc.mint(address(escrow), amount);
        ghostMinted += amount;
        ghostDonations += amount;
    }

    /// @dev Every attack must fail. Any success is a violation.
    function attack(uint256 which, uint256 reqSeed) external {
        uint256 id = ids.length == 0 ? 1 : ids[reqSeed % ids.length];
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        address[3] memory otherBuyers = buyers;
        address wrongBuyer = otherBuyers[0] == r.buyer ? otherBuyers[1] : otherBuyers[0];
        address wrongProvider = providers[0] == r.provider ? providers[1] : providers[0];
        address who;
        address target;
        bytes memory data;
        which = which % 17;
        if (which == 0) {
            (who, target, data) = (attacker, address(escrow), abi.encodeCall(escrow.release, (id)));
        } else if (which == 1) {
            (who, target, data) = (attacker, address(escrow), abi.encodeCall(escrow.refund, (id)));
        } else if (which == 2) {
            (who, target, data) = (attacker, address(escrow), abi.encodeCall(escrow.assignPayee, (id, attacker)));
        } else if (which == 3) {
            (who, target, data) = (attacker, address(escrow), abi.encodeWithSignature("withdraw()"));
        } else if (which == 4) {
            (who, target, data) =
            (attacker, address(registry), abi.encodeCall(registry.recordJobClosed, (id, r.provider)));
        } else if (which == 5) {
            (who, target, data) = (wrongBuyer, address(market), abi.encodeCall(market.confirmCompletion, (id)));
        } else if (which == 6) {
            (who, target, data) = (wrongBuyer, address(market), abi.encodeCall(market.cancelRequest, (id)));
        } else if (which == 7) {
            (who, target, data) = (wrongProvider, address(market), abi.encodeCall(market.startService, (id)));
        } else if (which == 8) {
            (who, target, data) = (r.buyer, address(market), abi.encodeCall(market.acceptRequest, (id)));
        } else if (which == 9) {
            (who, target, data) = (attacker, address(market), abi.encodeCall(market.acceptRequest, (id)));
        } else if (which == 10) {
            (who, target, data) = (attacker, address(pos), abi.encodeCall(pos.submit, (id, attacker, keccak256("x"))));
        } else if (which == 11) {
            (who, target, data) = (attacker, address(pos), abi.encodeCall(pos.approve, (id, verifier)));
        } else if (which == 12) {
            (who, target, data) = (attacker, address(pos), abi.encodeCall(pos.reject, (id, verifier, bytes32("r"))));
        } else if (which == 13) {
            (who, target, data) = (attacker, address(pos), abi.encodeCall(pos.markUnresolved, (id)));
        } else if (which == 14) {
            (who, target, data) = (attacker, address(rep), abi.encodeCall(rep.recordOutcome, (id, false)));
        } else if (which == 15) {
            // buyers[0] holds VERIFIER_ROLE: it still can never review its own request
            (who, target, data) = (r.buyer, address(market), abi.encodeCall(market.approveProof, (id)));
        } else {
            // providers[0] holds VERIFIER_ROLE: it still can never review its own job
            (who, target, data) = (r.provider, address(market), abi.encodeCall(market.approveProof, (id)));
        }
        vm.prank(who);
        (bool ok,) = target.call(data);
        if (ok) _fail("unauthorized call succeeded");
        _sync();
    }
}

contract ClinovaInvariantTest is ClinovaBase {
    MarketHandler internal handler;
    address[3] internal buyersArr;
    address[3] internal providersArr;
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        _eligible(dave);
        buyersArr = [buyer, buyer2, makeAddr("buyer3")];
        providersArr = [alice, bob, dave];
        // Initial supply: buyers' funding + provider stakes (4 registered providers incl. carol).
        uint256 minted = 2 * 1_000_000e6 + 4 * MIN_STAKE;
        handler = new MarketHandler(market, buyersArr, providersArr, carol, verifier, pauser, minted);
        targetContract(address(handler));
        // A buyer and a provider that also hold VERIFIER_ROLE: conflict-of-interest checks are exercised by attacks.
        bytes32 verifierRole = market.VERIFIER_ROLE();
        vm.startPrank(admin);
        market.grantRole(verifierRole, buyersArr[0]);
        market.grantRole(verifierRole, providersArr[0]);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Proof
    // ------------------------------------------------------------------

    /// Every proof belongs to exactly the request's accepted provider, with an onchain-bound hash and a spent
    /// (provider, commitment) pair. At most one proof per request (storage is keyed by request id).
    function invariant_ProofBoundToRequestAndProvider() public view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceProof memory proof = pos.getProof(id);
            if (proof.status == ClinovaTypes.ProofStatus.NONE) continue;
            assertEq(proof.provider, handler.acceptedBy(id), "proof provider == accepting provider");
            assertEq(proof.provider, market.getRequest(id).provider);
            assertEq(proof.proofHash, pos.computeProofHash(id, proof.provider, proof.evidenceCommitment));
            assertTrue(pos.evidenceUsed(proof.provider, proof.evidenceCommitment));
            assertTrue(handler.ghostProofSubmitted(id), "proof exists only after a successful provider submission");
        }
    }

    /// Proof status agrees with the request: payment <=> positive acceptance; rejection never pays;
    /// a finished request never leaves a proof open; a proof under review only on COMPLETED/DISPUTED.
    function invariant_ProofStatusAgreesWithRequest() public view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.Status st = market.getRequest(id).status;
            ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
            bool accepted = ps == ClinovaTypes.ProofStatus.APPROVED || ps == ClinovaTypes.ProofStatus.BUYER_ACCEPTED;
            assertEq(st == ClinovaTypes.Status.SETTLED, accepted, "SETTLED <=> APPROVED/BUYER_ACCEPTED");
            if (ps == ClinovaTypes.ProofStatus.REJECTED) {
                assertTrue(st == ClinovaTypes.Status.DISPUTED || st == ClinovaTypes.Status.REFUNDED);
            }
            if (ps == ClinovaTypes.ProofStatus.UNRESOLVED) assertEq(uint8(st), uint8(ClinovaTypes.Status.REFUNDED));
            if (ps == ClinovaTypes.ProofStatus.SUBMITTED) {
                assertTrue(st == ClinovaTypes.Status.COMPLETED || st == ClinovaTypes.Status.DISPUTED);
            }
            if (ClinovaTypes.isTerminal(st)) assertTrue(ps != ClinovaTypes.ProofStatus.SUBMITTED);
            if (st == ClinovaTypes.Status.COMPLETED) assertEq(uint8(ps), uint8(ClinovaTypes.ProofStatus.SUBMITTED));
        }
    }

    // ------------------------------------------------------------------
    // Reputation
    // ------------------------------------------------------------------

    /// Counters equal the handler's independent record of outcomes, attributed to the accepting provider.
    function invariant_ReputationMatchesOutcomes() public view {
        for (uint256 p = 0; p < 3; ++p) {
            address a = providersArr[p];
            ClinovaTypes.Reputation memory r = rep.getReputation(a);
            assertEq(r.completedJobs, handler.ghostCompleted(a), "completedJobs");
            assertEq(r.successfulJobs, handler.ghostSuccessful(a), "successfulJobs");
            assertEq(r.failedJobs, handler.ghostFailed(a), "failedJobs");
            assertEq(r.disputes, handler.ghostDisputes(a), "disputes");
        }
        ClinovaTypes.Reputation memory c = rep.getReputation(carol);
        assertEq(c.completedJobs + c.successfulJobs + c.failedJobs + c.disputes, 0, "never-accepted provider");
    }

    /// Exactly one outcome per finished accepted request (no double counting, none missing).
    function invariant_OneOutcomePerFinishedJob() public view {
        uint256 settled;
        uint256 successes;
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            bool finishedAccepted = registry.getJob(id).status == ClinovaTypes.JobStatus.CLOSED;
            assertEq(rep.outcomeRecorded(id), finishedAccepted);
            if (market.getRequest(id).status == ClinovaTypes.Status.SETTLED) settled++;
        }
        for (uint256 p = 0; p < 3; ++p) {
            successes += rep.getReputation(providersArr[p]).successfulJobs;
        }
        assertEq(successes, settled);
    }

    // ------------------------------------------------------------------
    // Accounting
    // ------------------------------------------------------------------

    /// Escrow USDC balance == locked + credited + direct donations (exact, not >=).
    function invariant_EscrowBalanceMatchesAccounting() public view {
        assertEq(
            usdc.balanceOf(address(escrow)), escrow.totalLocked() + escrow.totalCredited() + handler.ghostDonations()
        );
    }

    /// totalLocked == sum of prices of non-terminal requests; every deposit amount == its request price.
    function invariant_LockedMatchesOpenObligations() public view {
        uint256 locked;
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            assertEq(escrow.getDeposit(id).amount, r.price);
            if (!ClinovaTypes.isTerminal(r.status)) locked += r.price;
        }
        assertEq(escrow.totalLocked(), locked);
    }

    /// Per account: current credit + withdrawn == everything ever credited (no over-withdrawal, no theft).
    function invariant_CreditsMatchOutcomes() public view {
        uint256 sumCredit;
        for (uint256 i = 0; i < 3; ++i) {
            address[2] memory accts = [buyersArr[i], providersArr[i]];
            for (uint256 j = 0; j < 2; ++j) {
                address a = accts[j];
                assertEq(escrow.credit(a) + handler.ghostWithdrawn(a), handler.ghostCredited(a));
                sumCredit += escrow.credit(a);
            }
        }
        assertEq(escrow.totalCredited(), sumCredit, "credits only ever belong to parties");
        assertEq(escrow.credit(handler.attacker()) + escrow.credit(admin) + escrow.credit(verifier), 0);
    }

    /// No money is created or destroyed anywhere in the system.
    function invariant_GlobalConservation() public view {
        uint256 total = usdc.balanceOf(address(escrow)) + usdc.balanceOf(address(registry))
            + usdc.balanceOf(address(market)) + usdc.balanceOf(handler.attacker());
        for (uint256 i = 0; i < 3; ++i) {
            total += usdc.balanceOf(buyersArr[i]) + usdc.balanceOf(providersArr[i]);
        }
        total += usdc.balanceOf(carol);
        assertEq(total, handler.ghostMinted());
        assertEq(usdc.balanceOf(address(market)), 0, "marketplace never holds funds");
    }

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    /// Terminal request <-> terminal escrow state; settled <-> released; never both settled and refunded.
    function invariant_StatusAndEscrowStateAgree() public view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            ClinovaTypes.Deposit memory d = escrow.getDeposit(id);
            if (r.status == ClinovaTypes.Status.SETTLED) {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.RELEASED));
            } else if (ClinovaTypes.isTerminal(r.status)) {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.REFUNDED));
            } else {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.FUNDED));
            }
        }
    }

    /// A request has at most one provider, and escrow can only ever pay that provider.
    function invariant_SingleProviderAndBoundPayee() public view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            address payee = escrow.getDeposit(id).payee;
            if (payee != address(0)) {
                assertEq(payee, r.provider);
                assertEq(registry.getJob(id).provider, r.provider);
            }
            if (r.status == ClinovaTypes.Status.SETTLED) assertTrue(payee != address(0));
        }
    }

    /// Registry job accounting == marketplace lifecycle, for every provider and every request.
    function invariant_ActiveJobsMatchLifecycle() public view {
        uint32[3] memory counts;
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            bool active = r.status == ClinovaTypes.Status.ACCEPTED || r.status == ClinovaTypes.Status.IN_SERVICE
                || r.status == ClinovaTypes.Status.COMPLETED || r.status == ClinovaTypes.Status.DISPUTED;
            ClinovaTypes.JobStatus js = registry.getJob(id).status;
            if (active) {
                assertEq(uint8(js), uint8(ClinovaTypes.JobStatus.OPEN));
                for (uint256 p = 0; p < 3; ++p) {
                    if (r.provider == providersArr[p]) counts[p]++;
                }
            } else if (r.status == ClinovaTypes.Status.OPEN || r.status == ClinovaTypes.Status.CANCELLED) {
                assertEq(uint8(js), uint8(ClinovaTypes.JobStatus.NONE));
            } else if (registry.getJob(id).provider != address(0)) {
                assertEq(uint8(js), uint8(ClinovaTypes.JobStatus.CLOSED));
            }
        }
        for (uint256 p = 0; p < 3; ++p) {
            assertEq(registry.getProvider(providersArr[p]).activeJobs, counts[p]);
        }
        assertEq(registry.getProvider(carol).activeJobs, 0);
    }

    /// No terminal status ever changed, no provider was ever replaced, no unauthorized call succeeded.
    function invariant_NoViolations() public view {
        assertFalse(handler.violation(), handler.violationReason());
    }

    // ------------------------------------------------------------------
    // Liveness: no sequence of calls can permanently lock funds
    // ------------------------------------------------------------------

    /// From ANY reachable state, while PAUSED and with NO verifier and NO admin action, every request can be
    /// driven to a terminal state and every credit withdrawn: escrow ends with only donations, all provider
    /// jobs close. State is restored afterwards.
    function invariant_NoPermanentLock() public {
        uint256 snap = vm.snapshotState();
        if (!market.paused()) {
            vm.prank(pauser);
            market.pause();
        }
        bytes32 verifierRole = market.VERIFIER_ROLE();
        vm.prank(admin);
        market.revokeRole(verifierRole, verifier);
        vm.warp(block.timestamp + 200 days);

        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            if (r.status == ClinovaTypes.Status.OPEN) {
                market.expireRequest(id);
            } else if (r.status == ClinovaTypes.Status.ACCEPTED || r.status == ClinovaTypes.Status.IN_SERVICE) {
                vm.prank(r.provider); // the provider alone can free its stake
                market.expireRequest(id);
            } else if (r.status == ClinovaTypes.Status.COMPLETED) {
                market.closeUnreviewed(id);
            } else if (r.status == ClinovaTypes.Status.DISPUTED) {
                market.resolveDisputeByTimeout(id);
            }
            assertTrue(ClinovaTypes.isTerminal(market.getRequest(id).status));
        }
        for (uint256 i = 0; i < 3; ++i) {
            address[2] memory accts = [buyersArr[i], providersArr[i]];
            for (uint256 j = 0; j < 2; ++j) {
                if (escrow.credit(accts[j]) > 0) {
                    vm.prank(accts[j]);
                    escrow.withdraw();
                }
            }
            assertEq(registry.getProvider(providersArr[i]).activeJobs, 0);
        }
        assertEq(escrow.totalLocked(), 0);
        assertEq(escrow.totalCredited(), 0);
        assertEq(usdc.balanceOf(address(escrow)), handler.ghostDonations());
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------
    // Handler smoke test: the deep paths really succeed (guards against vacuous invariants)
    // ------------------------------------------------------------------

    function test_HandlerReachesEveryPath() public {
        for (uint256 i = 0; i < 12; ++i) {
            handler.create(i, 1, 10e6, 1 days, 2 days);
        }
        handler.cancel(0); // OPEN -> CANCELLED
        for (uint256 i = 0; i < 10; ++i) {
            handler.accept(i, 1); // leaves exactly one OPEN request
        }
        for (uint256 i = 0; i < 6; ++i) {
            handler.start(i);
        }
        for (uint256 i = 1; i <= 4; ++i) {
            handler.submitProof(i, false); // 4 x IN_SERVICE -> COMPLETED
        }
        handler.confirm(0); // COMPLETED -> SETTLED (buyer; proof BUYER_ACCEPTED)
        handler.approve(0); // COMPLETED -> SETTLED (verifier; proof APPROVED)
        handler.reject(0); // COMPLETED -> DISPUTED (proof REJECTED)
        handler.resolve(0, 1); // REFUND_PROVIDER_FAULT on the rejected one
        handler.dispute(3, false); // buyer disputes the last COMPLETED
        handler.resolve(0, 0); // PROVIDER_WINS (proof SUBMITTED -> APPROVED)
        handler.dispute(1, false); // ACCEPTED -> DISPUTED (buyer)
        handler.submitProof(1, true); // proof into dispute
        handler.resolve(0, 2); // REFUND_NO_FAULT (proof -> REJECTED)
        handler.dispute(2, true); // ACCEPTED -> DISPUTED (provider)
        handler.submitProof(1, false); // IN_SERVICE -> COMPLETED
        // Time-dependent exits last (each may warp).
        handler.closeUnreviewed(0, true); // nobody reviewed -> no-fault refund
        handler.expire(1, true, true); // provider expires a missed-deadline job (fault)
        handler.timeout(0, true); // unresolved dispute
        handler.expire(3, false, true); // the OPEN request, by anyone
        for (uint256 i = 0; i < 6; ++i) {
            handler.withdraw(i);
        }
        string[18] memory keys = [
            "create",
            "cancel",
            "expire",
            "accept",
            "start",
            "proof",
            "proofIntoDispute",
            "confirm",
            "approve",
            "reject",
            "dispute",
            "resolve_pw",
            "resolve_pf",
            "resolve_nf",
            "timeout",
            "closeUnreviewed",
            "withdraw",
            "accept"
        ];
        for (uint256 i = 0; i < keys.length; ++i) {
            assertGt(handler.successes(bytes32(bytes(keys[i]))), 0, keys[i]);
        }
        assertFalse(handler.violation(), handler.violationReason());
        // Reputation actually moved on every counter.
        uint256 completed;
        uint256 successful;
        uint256 failed;
        uint256 disputes;
        for (uint256 p = 0; p < 3; ++p) {
            ClinovaTypes.Reputation memory r = rep.getReputation(providersArr[p]);
            completed += r.completedJobs;
            successful += r.successfulJobs;
            failed += r.failedJobs;
            disputes += r.disputes;
        }
        assertGt(completed, 0, "completedJobs");
        assertGt(successful, 0, "successfulJobs");
        assertGt(failed, 0, "failedJobs");
        assertGt(disputes, 0, "disputes");
        invariant_EscrowBalanceMatchesAccounting();
        invariant_CreditsMatchOutcomes();
        invariant_ActiveJobsMatchLifecycle();
        invariant_ProofBoundToRequestAndProvider();
        invariant_ProofStatusAgreesWithRequest();
        invariant_ReputationMatchesOutcomes();
        invariant_OneOutcomePerFinishedJob();
        invariant_NoPermanentLock();
    }
}
