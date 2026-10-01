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

/// @notice Whole-protocol handler (Phase 5). Drives all five contracts together: request lifecycle, the full provider
///         lifecycle (stake, unbond, withdraw, deactivate, capability/profile churn, verification revoke/re-verify),
///         verifier role grants/revocations mid-flow, bounded admin parameter changes, pause/unpause of both pausable
///         contracts, withdrawTo, direct donations, commitment replay/copying and an attack set.
/// @dev Non-vacuity: every action REVERTS when its protocol call fails (fail_on_revert = false discards it), so the
///      invariant metrics table reports, per action, calls - reverts = successful protocol transitions in the actual
///      random campaign. Attacks are the exception: they never revert; a successful attack sets `violation`.
///      Ghost state is written only from observed successes and from `_sync`, which re-reads every request after
///      every action, so transitions caused by any action (including attacks) are accounted for.
contract SystemHandler is Test {
    error ActionFailed();

    ServiceMarketplace public immutable market;
    ClinovaEscrow public immutable escrow;
    ProviderRegistry public immutable registry;
    ProofOfService public immutable pos;
    ReputationRegistry public immutable rep;
    MockUSDC public immutable usdc;
    address public immutable admin;
    address public immutable pauser;
    address public immutable attacker;

    address[3] public buyers;
    address[4] public providers; // [3] starts registered but unverified
    address[2] public verifiers; // [0]: registry + marketplace role; [1]: marketplace role only
    bytes32[3] public serviceTypes;

    uint256[] public ids;
    uint256[] internal live; // non-terminal ids: re-observed after every action
    uint256 public constant MAX_REQUESTS = 60;
    uint256 internal commitmentNonce;

    // --- escrow ghosts ---
    uint256 public ghostFunded;
    uint256 public ghostReleased;
    uint256 public ghostRefunded;
    uint256 public ghostEscrowDonations;
    uint256 public ghostRegistryDonations;
    uint256 public ghostMinted;
    mapping(uint256 => ClinovaTypes.EscrowState) public lastEscrowState;
    mapping(address => uint256) public ghostCredited;
    mapping(address => uint256) public ghostWithdrawn;
    mapping(address => uint256) public ghostPaidToProvider;
    // --- stake ghosts ---
    mapping(address => uint256) public ghostStakeIn;
    mapping(address => uint256) public ghostStakeOut;
    // --- binding / proof / reputation ghosts ---
    mapping(uint256 => address) public acceptedBy;
    mapping(address => bool) public everAccepted;
    mapping(uint256 => bool) public ghostProofSubmitted;
    mapping(uint256 => bool) public ghostDisputed;
    mapping(uint256 => bool) public ghostFault;
    mapping(uint256 => ClinovaTypes.ProofStatus) public ghostProofFinal;
    mapping(uint256 => bool) public terminalSeen;
    mapping(uint256 => ClinovaTypes.Status) public terminalStatus;
    mapping(address => uint64) public ghostCompleted;
    mapping(address => uint64) public ghostSuccessful;
    mapping(address => uint64) public ghostFailed;
    mapping(address => uint64) public ghostDisputes;
    mapping(address => mapping(bytes32 => bool)) internal usedBy;
    bytes32[] internal usedCommitments;

    bool public violation;
    string public violationReason;

    constructor(
        ServiceMarketplace m,
        address admin_,
        address pauser_,
        address[3] memory buyers_,
        address[4] memory providers_,
        address[2] memory verifiers_,
        bytes32[3] memory serviceTypes_
    ) {
        market = m;
        escrow = ClinovaEscrow(address(m.escrow()));
        registry = ProviderRegistry(address(m.registry()));
        pos = ProofOfService(address(m.proofOfService()));
        rep = ReputationRegistry(address(m.reputation()));
        usdc = MockUSDC(address(m.usdc()));
        admin = admin_;
        pauser = pauser_;
        attacker = makeAddr("sys-attacker");
        buyers = buyers_;
        providers = providers_;
        verifiers = verifiers_;
        serviceTypes = serviceTypes_;
        for (uint256 i = 0; i < 4; ++i) {
            ghostStakeIn[providers_[i]] = registry.getProvider(providers_[i]).stake;
        }
    }

    /// Initial token supply, set once by the test after setUp minting.
    function setInitialMinted(uint256 v) external {
        ghostMinted = v;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function coldOf(address a) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("cold", a)))));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// First request (rotating from `seed`) in status `want` whose relevant window is still open, else the first
    /// in that status, else a random one (so failure paths are exercised too).
    function _pick(uint256 seed, ClinovaTypes.Status want) internal view returns (uint256 id) {
        uint256 n = ids.length;
        if (n == 0) return 0;
        uint256 fallbackId = ids[seed % n];
        bool found;
        for (uint256 i = 0; i < n; ++i) {
            uint256 c = ids[(seed % n + i) % n];
            ClinovaTypes.ServiceRequest memory r = market.getRequest(c);
            if (r.status != want) continue;
            if (_inWindow(r)) return c;
            if (!found) (fallbackId, found) = (c, true);
        }
        return fallbackId;
    }

    function _inWindow(ClinovaTypes.ServiceRequest memory r) internal view returns (bool) {
        if (r.status == ClinovaTypes.Status.OPEN) return vm.getBlockTimestamp() <= r.acceptDeadline;
        if (r.status == ClinovaTypes.Status.COMPLETED) return vm.getBlockTimestamp() <= r.reviewDeadline;
        if (r.status == ClinovaTypes.Status.DISPUTED) return vm.getBlockTimestamp() <= r.disputeDeadline;
        return vm.getBlockTimestamp() <= r.serviceDeadline; // ACCEPTED, IN_SERVICE
    }

    function _pick2(uint256 seed, ClinovaTypes.Status a, ClinovaTypes.Status b) internal view returns (uint256 id) {
        id = _pick(seed, a);
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        if (r.status != a || !_inWindow(r)) id = _pick(seed >> 8, b);
    }

    function _do(address who, address target, bytes memory data) internal {
        vm.prank(who);
        (bool ok,) = target.call(data);
        if (!ok) revert ActionFailed();
        _sync();
    }

    /// A marketplace verifier that currently holds the role (one call in four: an arbitrary one, which may not).
    function _verifier(uint256 vSeed) internal view returns (address) {
        address v = verifiers[vSeed % 2];
        if (vSeed % 4 == 0 || market.hasRole(market.VERIFIER_ROLE(), v)) return v;
        return verifiers[(vSeed + 1) % 2];
    }

    function _fail(string memory reason) internal {
        if (!violation) violationReason = reason;
        violation = true;
    }

    function _liveJobsOf(address p) public view returns (uint256 n) {
        for (uint256 i = 0; i < ids.length; ++i) {
            ClinovaTypes.ServiceRequest memory r = market.getRequest(ids[i]);
            if (r.provider != p) continue;
            if (
                r.status == ClinovaTypes.Status.ACCEPTED || r.status == ClinovaTypes.Status.IN_SERVICE
                    || r.status == ClinovaTypes.Status.COMPLETED || r.status == ClinovaTypes.Status.DISPUTED
            ) n++;
        }
    }

    /// Observe every non-terminal request after every action: escrow-state monotonicity, payments, terminal
    /// outcomes. Requests that became terminal leave the live set; `terminalsIntact()` re-checks all of them.
    function _sync() internal {
        uint256 i;
        while (i < live.length) {
            uint256 id = live[i];
            _syncOne(id);
            if (terminalSeen[id]) {
                live[i] = live[live.length - 1];
                live.pop();
            } else {
                ++i;
            }
        }
    }

    /// Terminal requests never change status, escrow state or final proof status.
    function terminalsIntact() external view returns (bool) {
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (!terminalSeen[id]) continue;
            if (market.getRequest(id).status != terminalStatus[id]) return false;
            if (escrow.getDeposit(id).state != lastEscrowState[id]) return false;
            ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
            if (ps != ghostProofFinal[id] && !(ps == ClinovaTypes.ProofStatus.NONE)) return false;
        }
        return true;
    }

    function _syncOne(uint256 id) internal {
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        ClinovaTypes.Deposit memory d = escrow.getDeposit(id);
        // escrow state machine: NONE -> FUNDED -> (RELEASED | REFUNDED), observed independently of the marketplace
        ClinovaTypes.EscrowState last = lastEscrowState[id];
        if (d.state != last) {
            if (last == ClinovaTypes.EscrowState.FUNDED && d.state == ClinovaTypes.EscrowState.RELEASED) {
                ghostReleased += d.amount;
                ghostPaidToProvider[d.payee] += d.amount;
                if (d.payee != acceptedBy[id]) _fail("released to someone other than the accepting provider");
            } else if (last == ClinovaTypes.EscrowState.FUNDED && d.state == ClinovaTypes.EscrowState.REFUNDED) {
                ghostRefunded += d.amount;
            } else if (!(last == ClinovaTypes.EscrowState.NONE && d.state == ClinovaTypes.EscrowState.FUNDED)) {
                _fail("illegal escrow transition");
            }
            lastEscrowState[id] = d.state;
        }
        if (acceptedBy[id] != address(0) && r.provider != acceptedBy[id]) _fail("provider replaced");
        ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
        if (ps != ClinovaTypes.ProofStatus.NONE && ps != ClinovaTypes.ProofStatus.SUBMITTED) {
            if (ghostProofFinal[id] == ClinovaTypes.ProofStatus.NONE) ghostProofFinal[id] = ps;
            else if (ghostProofFinal[id] != ps) _fail("final proof status changed");
        }
        if (terminalSeen[id]) {
            if (r.status != terminalStatus[id]) _fail("terminal status changed");
            return;
        }
        if (!ClinovaTypes.isTerminal(r.status)) return;
        terminalSeen[id] = true;
        terminalStatus[id] = r.status;
        ghostCredited[r.status == ClinovaTypes.Status.SETTLED ? r.provider : r.buyer] += r.price;
        address p = acceptedBy[id];
        if (p == address(0)) return;
        if (ghostProofSubmitted[id]) ghostCompleted[p]++;
        if (r.status == ClinovaTypes.Status.SETTLED) ghostSuccessful[p]++;
        if (r.status == ClinovaTypes.Status.EXPIRED || (r.status == ClinovaTypes.Status.REFUNDED && ghostFault[id])) {
            ghostFailed[p]++;
        }
        if (ghostDisputed[id]) ghostDisputes[p]++;
    }

    // ------------------------------------------------------------------
    // Request lifecycle
    // ------------------------------------------------------------------

    function create(uint256 buyerSeed, uint256 directedSeed, uint256 typeSeed, uint128 price, uint64 aOff, uint64 sOff)
        external
    {
        if (ids.length >= MAX_REQUESTS) revert ActionFailed();
        address b = buyers[buyerSeed % 3];
        price = uint128(bound(price, market.minPrice(), market.minPrice() + 500e6));
        uint64 a = uint64(vm.getBlockTimestamp() + bound(aOff, 1 hours, 7 days));
        uint64 s = uint64(a + bound(sOff, 6 hours, 30 days));
        address directed = directedSeed % 4 == 0 ? providers[(directedSeed >> 2) % 4] : address(0);
        usdc.mint(b, price);
        vm.prank(b);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(b);
        try market.createRequest(directed, serviceTypes[typeSeed % 3], keccak256("region"), price, a, s) returns (
            uint256 id
        ) {
            ghostMinted += price;
            ghostFunded += price;
            ids.push(id);
            live.push(id);
            _sync();
        } catch {
            revert ActionFailed();
        }
    }

    /// Prefers an (OPEN request, provider) pair that can succeed right now despite lifecycle churn: a directed
    /// request whose provider is eligible, or an undirected one with any eligible provider for its service type.
    /// One call in five deliberately uses an arbitrary pair instead, which usually fails.
    function accept(uint256 reqSeed, uint256 provSeed) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.OPEN);
        address p = providers[provSeed % 4];
        if (provSeed % 5 != 0) (id, p) = _acceptablePair(reqSeed, provSeed, id, p);
        acceptedBy[id] = p; // must be known before _sync observes the payee
        vm.prank(p);
        (bool ok,) = address(market).call(abi.encodeCall(market.acceptRequest, (id)));
        if (!ok) revert ActionFailed();
        everAccepted[p] = true;
        _sync();
    }

    function _acceptablePair(uint256 reqSeed, uint256 provSeed, uint256 id0, address p0)
        internal
        view
        returns (uint256, address)
    {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = ids[(reqSeed % n + i) % n];
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            if (r.status != ClinovaTypes.Status.OPEN || vm.getBlockTimestamp() > r.acceptDeadline) continue;
            for (uint256 j = 0; j < 4; ++j) {
                address c = r.provider != address(0) ? r.provider : providers[(provSeed % 4 + j) % 4];
                if (registry.isEligible(c, r.serviceType)) return (id, c);
                if (r.provider != address(0)) break;
            }
        }
        return (id0, p0);
    }

    function start(uint256 reqSeed) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.ACCEPTED);
        _do(market.getRequest(id).provider, address(market), abi.encodeCall(market.startService, (id)));
    }

    /// mode: 0 = replay one of this provider's own earlier commitments (must fail), 1 = copy a commitment used by
    /// another provider (allowed: per-provider scope), otherwise fresh.
    function submitProof(uint256 reqSeed, bool preferDispute, uint8 mode) external {
        uint256 id = preferDispute
            ? _pick2(reqSeed, ClinovaTypes.Status.DISPUTED, ClinovaTypes.Status.IN_SERVICE)
            : _pick2(reqSeed, ClinovaTypes.Status.IN_SERVICE, ClinovaTypes.Status.DISPUTED);
        address p = market.getRequest(id).provider;
        bytes32 c = keccak256(abi.encode("c", ++commitmentNonce));
        if (usedCommitments.length > 0 && mode % 4 < 2) c = usedCommitments[reqSeed % usedCommitments.length];
        bool replay = usedBy[p][c];
        ghostProofSubmitted[id] = true;
        vm.prank(p);
        (bool ok,) = address(market).call(abi.encodeCall(market.submitProof, (id, c)));
        if (!ok) revert ActionFailed();
        if (replay) _fail("same provider reused a commitment");
        usedBy[p][c] = true;
        usedCommitments.push(c);
        _sync();
    }

    function confirm(uint256 reqSeed) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        _do(market.getRequest(id).buyer, address(market), abi.encodeCall(market.confirmCompletion, (id)));
    }

    function approve(uint256 reqSeed, uint256 vSeed) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        _do(_verifier(vSeed), address(market), abi.encodeCall(market.approveProof, (id)));
    }

    function reject(uint256 reqSeed, uint256 vSeed) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        ghostDisputed[id] = true;
        _do(_verifier(vSeed), address(market), abi.encodeCall(market.rejectProof, (id, keccak256("why"))));
    }

    function dispute(uint256 reqSeed, bool byProvider) external {
        uint256 id = reqSeed % 3 == 0
            ? _pick(reqSeed, ClinovaTypes.Status.COMPLETED)
            : _pick2(reqSeed, ClinovaTypes.Status.ACCEPTED, ClinovaTypes.Status.IN_SERVICE);
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        ghostDisputed[id] = true;
        _do(
            byProvider ? r.provider : r.buyer, address(market), abi.encodeCall(market.openDispute, (id, keccak256("w")))
        );
    }

    function resolve(uint256 reqSeed, uint8 res, uint256 vSeed) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.DISPUTED);
        ClinovaTypes.Resolution resolution = ClinovaTypes.Resolution(res % 3);
        ghostFault[id] = resolution == ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT;
        _do(_verifier(vSeed), address(market), abi.encodeCall(market.resolveDispute, (id, resolution)));
    }

    /// One call in three: cancellation always succeeds on an OPEN request and would otherwise starve acceptance.
    function cancel(uint256 reqSeed) external {
        if (reqSeed % 3 != 0) revert ActionFailed();
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.OPEN);
        _do(market.getRequest(id).buyer, address(market), abi.encodeCall(market.cancelRequest, (id)));
    }

    function expire(uint256 reqSeed, bool byProvider, bool warpPast) external {
        uint256 id = reqSeed % 3 == 0
            ? _pick(reqSeed, ClinovaTypes.Status.OPEN)
            : _pick2(reqSeed, ClinovaTypes.Status.ACCEPTED, ClinovaTypes.Status.IN_SERVICE);
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        bool open = r.status == ClinovaTypes.Status.OPEN;
        uint64 deadline = open ? r.acceptDeadline : r.serviceDeadline;
        if (warpPast && (open ? reqSeed % 3 == 0 : reqSeed % 2 == 0) && vm.getBlockTimestamp() <= deadline) {
            vm.warp(uint256(deadline) + 1);
        }
        _do(
            open ? attacker : (byProvider ? r.provider : r.buyer),
            address(market),
            abi.encodeCall(market.expireRequest, (id))
        );
    }

    function closeUnreviewed(uint256 reqSeed, bool warpPast) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.COMPLETED);
        uint64 rd = market.getRequest(id).reviewDeadline;
        if (warpPast && reqSeed % 3 == 0 && vm.getBlockTimestamp() <= rd) vm.warp(uint256(rd) + 1);
        _do(attacker, address(market), abi.encodeCall(market.closeUnreviewed, (id)));
    }

    function timeout(uint256 reqSeed, bool warpPast) external {
        uint256 id = _pick(reqSeed, ClinovaTypes.Status.DISPUTED);
        uint64 dd = market.getRequest(id).disputeDeadline;
        if (warpPast && reqSeed % 3 == 0 && vm.getBlockTimestamp() <= dd) vm.warp(uint256(dd) + 1);
        _do(attacker, address(market), abi.encodeCall(market.resolveDisputeByTimeout, (id)));
    }

    function withdraw(uint256 seed, bool toCold) external {
        address who = seed % 2 == 0 ? buyers[(seed >> 1) % 3] : providers[(seed >> 1) % 4];
        address to = toCold ? coldOf(who) : who;
        uint256 before = usdc.balanceOf(to);
        vm.prank(who);
        (bool ok, bytes memory ret) = toCold
            ? address(escrow).call(abi.encodeCall(escrow.withdrawTo, (to)))
            : address(escrow).call(abi.encodeWithSignature("withdraw()"));
        if (!ok) revert ActionFailed();
        uint256 amount = abi.decode(ret, (uint256));
        ghostWithdrawn[who] += amount;
        if (usdc.balanceOf(to) - before != amount) _fail("withdraw amount mismatch");
    }

    // ------------------------------------------------------------------
    // Provider lifecycle
    // ------------------------------------------------------------------

    /// Restorative actions target a provider that needs them (kind 0: unverified, 1: activatable, 2: under-staked
    /// and not unbonding, 3: unbonding); disruptive actions pick at random. Without this, churn makes every provider
    /// ineligible and the campaign stalls in shallow states (observed while building this suite).
    function _providerNeeding(uint256 seed, uint8 kind) internal view returns (address) {
        uint256 minStake = registry.minStake();
        for (uint256 i = 0; i < 4; ++i) {
            address p = providers[(seed % 4 + i) % 4];
            ClinovaTypes.Provider memory pr = registry.getProvider(p);
            if (kind == 0 && !pr.verified) return p;
            if (kind == 1 && pr.verified && !pr.active && pr.unstakeAvailableAt == 0 && pr.stake >= minStake) return p;
            if (kind == 2 && pr.unstakeAvailableAt == 0 && pr.stake < minStake) return p;
            if (kind == 3 && pr.unstakeAvailableAt != 0) return p;
        }
        return providers[seed % 4];
    }

    function providerDeactivate(uint256 pSeed) external {
        _do(providers[pSeed % 4], address(registry), abi.encodeCall(registry.deactivate, ()));
    }

    function providerActivate(uint256 pSeed) external {
        _do(_providerNeeding(pSeed, 1), address(registry), abi.encodeCall(registry.activate, ()));
    }

    /// One call in three: unbonding blocks a provider for days, so it must not dominate the campaign.
    function providerRequestUnstake(uint256 pSeed) external {
        if (pSeed % 3 != 0) revert ActionFailed();
        _do(providers[pSeed % 4], address(registry), abi.encodeCall(registry.requestUnstake, ()));
    }

    /// Stake may leave only with no open obligation: checked against the MARKETPLACE's view, not just the registry.
    function providerWithdrawStake(uint256 pSeed, bool warpPast) external {
        _withdrawStake(_providerNeeding(pSeed, 3), warpPast);
    }

    function _withdrawStake(address p, bool warpPast) internal {
        ClinovaTypes.Provider memory pr = registry.getProvider(p);
        if (warpPast && pr.unstakeAvailableAt > vm.getBlockTimestamp()) vm.warp(pr.unstakeAvailableAt);
        uint256 live = _liveJobsOf(p);
        uint256 before = usdc.balanceOf(p);
        _do(p, address(registry), abi.encodeCall(registry.withdrawStake, ()));
        if (live != 0 || pr.activeJobs != 0) _fail("stake withdrawn with an open obligation");
        uint256 out = usdc.balanceOf(p) - before;
        if (out != pr.stake) _fail("stake withdrawal amount mismatch");
        ghostStakeOut[p] += out;
    }

    function providerDeposit(uint256 pSeed, uint256 amount) external {
        _deposit(_providerNeeding(pSeed, 2), amount);
    }

    function _deposit(address p, uint256 amount) internal {
        uint256 shortfall = registry.minStake() > registry.getProvider(p).stake
            ? registry.minStake() - registry.getProvider(p).stake
            : 0;
        amount = shortfall + bound(amount, 1e6, 100e6);
        usdc.mint(p, amount);
        ghostMinted += amount;
        vm.prank(p);
        usdc.approve(address(registry), amount);
        vm.prank(p);
        (bool ok,) = address(registry).call(abi.encodeCall(registry.depositStake, (amount)));
        if (!ok) revert ActionFailed();
        ghostStakeIn[p] += amount;
    }

    /// Performs the single next protocol call that brings an ineligible provider back (withdraw after unbonding,
    /// top up stake, re-verification, activation). Balances the disruptive lifecycle actions.
    function providerRecover(uint256 pSeed) external {
        uint256 minStake = registry.minStake();
        for (uint256 i = 0; i < 4; ++i) {
            address p = providers[(pSeed % 4 + i) % 4];
            ClinovaTypes.Provider memory pr = registry.getProvider(p);
            if (pr.unstakeAvailableAt != 0) {
                if (_liveJobsOf(p) != 0) continue; // cannot exit yet
                return _withdrawStake(p, true);
            }
            if (pr.stake < minStake) return _deposit(p, pSeed);
            if (!pr.verified) {
                return _do(verifiers[0], address(registry), abi.encodeCall(registry.verifyProvider, (p)));
            }
            if (!pr.active) return _do(p, address(registry), abi.encodeCall(registry.activate, ()));
        }
        revert ActionFailed();
    }

    /// Capability/profile churn (two of three variants revoke verification); half the calls are no-ops so that
    /// revocation does not outpace re-verification.
    function providerChurn(uint256 pSeed, uint8 what, uint256 typeSeed) external {
        if (typeSeed % 2 == 0) revert ActionFailed();
        address p = providers[pSeed % 4];
        bytes32 t = serviceTypes[typeSeed % 3];
        bytes memory data;
        if (what % 3 == 0) data = abi.encodeCall(registry.addCapability, (t)); // revokes verification
        else if (what % 3 == 1) data = abi.encodeCall(registry.removeCapability, (t));
        else data = abi.encodeCall(registry.updateProfile, (keccak256(abi.encode(typeSeed)), keccak256("region")));
        _do(p, address(registry), data);
    }

    function registryVerify(uint256 pSeed) external {
        _do(verifiers[0], address(registry), abi.encodeCall(registry.verifyProvider, (_providerNeeding(pSeed, 0))));
    }

    function registryRevoke(uint256 pSeed) external {
        if ((pSeed >> 4) % 2 == 0) revert ActionFailed();
        _do(verifiers[0], address(registry), abi.encodeCall(registry.revokeVerification, (providers[pSeed % 4])));
    }

    // ------------------------------------------------------------------
    // Roles, parameters, pause, time, donations
    // ------------------------------------------------------------------

    /// Grants or revokes a marketplace verifier mid-flow; zero-verifier periods happen naturally.
    function toggleMarketVerifier(uint256 vSeed) external {
        address v = verifiers[vSeed % 2];
        bytes32 role = market.VERIFIER_ROLE();
        bytes memory data = market.hasRole(role, v)
            ? abi.encodeCall(market.revokeRole, (role, v))
            : abi.encodeCall(market.grantRole, (role, v));
        _do(admin, address(market), data);
    }

    function adminParams(uint8 which, uint256 v) external {
        bytes memory data;
        address target = address(market);
        which = which % 5;
        if (which == 0) {
            data = abi.encodeCall(market.setReviewPeriod, (uint32(bound(v, 1 days, 14 days))));
        } else if (which == 1) {
            data = abi.encodeCall(market.setDisputePeriod, (uint32(bound(v, 3 days, 60 days))));
        } else if (which == 2) {
            data = abi.encodeCall(market.setMinPrice, (bound(v, 1e6, 20e6)));
        } else if (which == 3) {
            (target, data) = (address(registry), abi.encodeCall(registry.setMinStake, (bound(v, 50e6, 150e6))));
        } else {
            (target, data) =
            (address(registry), abi.encodeCall(registry.setUnbondingPeriod, (uint64(bound(v, 1 days, 30 days)))));
        }
        _do(admin, target, data);
    }

    /// Pauses one call in four, unpauses otherwise: paused periods happen without dominating the campaign.
    function togglePause(bool registrySide, uint8 seed) external {
        address target = registrySide ? address(registry) : address(market);
        bool paused = registrySide ? registry.paused() : market.paused();
        if (!paused && seed % 4 != 0) revert ActionFailed();
        _do(pauser, target, paused ? abi.encodeWithSignature("unpause()") : abi.encodeWithSignature("pause()"));
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 1 days));
    }

    function donate(uint256 amount, bool toRegistry) external {
        amount = bound(amount, 1, 5e6);
        address to = toRegistry ? address(registry) : address(escrow);
        usdc.mint(to, amount);
        ghostMinted += amount;
        if (toRegistry) ghostRegistryDonations += amount;
        else ghostEscrowDonations += amount;
    }

    // ------------------------------------------------------------------
    // Attacks: every one must fail
    // ------------------------------------------------------------------

    function attack(uint256 which, uint256 seed) external {
        uint256 id = ids.length == 0 ? 1 : ids[seed % ids.length];
        ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
        address wrongBuyer = buyers[0] == r.buyer ? buyers[1] : buyers[0];
        address wrongProvider = providers[0] == r.provider ? providers[1] : providers[0];
        address who = attacker;
        address target = address(market);
        bytes memory data;
        which = which % 20;
        if (which == 0) {
            (who, target, data) = (admin, address(escrow), abi.encodeCall(escrow.release, (id)));
        } else if (which == 1) {
            (who, target, data) = (admin, address(escrow), abi.encodeCall(escrow.refund, (id)));
        } else if (which == 2) {
            (target, data) = (address(escrow), abi.encodeCall(escrow.assignPayee, (id, attacker)));
        } else if (which == 3) {
            (who, target, data) = (admin, address(escrow), abi.encodeWithSignature("withdraw()"));
        } else if (which == 4) {
            (who, target, data) = (admin, address(registry), abi.encodeCall(registry.recordJobClosed, (id, r.provider)));
        } else if (which == 5) {
            (who, target, data) = (admin, address(registry), abi.encodeWithSignature("withdrawStake()"));
        } else if (which == 6) {
            (who, target, data) = (admin, address(pos), abi.encodeCall(pos.approve, (id, verifiers[0])));
        } else if (which == 7) {
            (who, target, data) = (admin, address(rep), abi.encodeCall(rep.recordOutcome, (id, false)));
        } else if (which == 8) {
            (who, data) = (wrongBuyer, abi.encodeCall(market.confirmCompletion, (id)));
        } else if (which == 9) {
            (who, data) = (wrongBuyer, abi.encodeCall(market.cancelRequest, (id)));
        } else if (which == 10) {
            (who, data) = (wrongProvider, abi.encodeCall(market.startService, (id)));
        } else if (which == 11) {
            (who, data) = (wrongProvider, abi.encodeCall(market.submitProof, (id, keccak256("x"))));
        } else if (which == 12) {
            (who, data) = (r.buyer, abi.encodeCall(market.acceptRequest, (id)));
        } else if (which == 13) {
            (who, data) = (r.buyer, abi.encodeCall(market.approveProof, (id))); // holds VERIFIER_ROLE
        } else if (which == 14) {
            (who, data) = (r.provider, abi.encodeCall(market.approveProof, (id))); // ditto
        } else if (which == 15) {
            (who, data) =
            (r.provider, abi.encodeCall(market.resolveDispute, (id, ClinovaTypes.Resolution.PROVIDER_WINS)));
        } else if (which == 16) {
            (who, target, data) =
            (verifiers[1], address(registry), abi.encodeCall(registry.verifyProvider, (providers[3])));
        } else if (which == 17) {
            // Only parties may expire an ACCEPTED/IN_SERVICE job (expiring an OPEN one is permissionless, T4).
            if (r.status != ClinovaTypes.Status.ACCEPTED && r.status != ClinovaTypes.Status.IN_SERVICE) return;
            (who, data) = (wrongProvider, abi.encodeCall(market.expireRequest, (id)));
        } else if (which == 18) {
            (target, data) = (address(pos), abi.encodeCall(pos.submit, (id, attacker, keccak256("x"))));
        } else {
            // A provider with an open obligation tries to take its stake out.
            for (uint256 i = 0; i < 4; ++i) {
                if (registry.getProvider(providers[i]).activeJobs > 0) {
                    who = providers[i];
                    break;
                }
            }
            (target, data) = (address(registry), abi.encodeWithSignature("withdrawStake()"));
            if (who == attacker) return; // nobody has an obligation right now
            ClinovaTypes.Provider memory pr = registry.getProvider(who);
            if (pr.unstakeAvailableAt != 0 && pr.unstakeAvailableAt > vm.getBlockTimestamp()) {
                vm.warp(pr.unstakeAvailableAt);
            }
        }
        vm.prank(who);
        (bool ok,) = target.call(data);
        if (ok) _fail(string.concat("attack succeeded: ", vm.toString(which)));
        _sync();
    }
}

/// @notice Phase 5 whole-protocol invariants (§5 A-F, plus global conservation, terminal immutability and liveness).
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
contract ClinovaSystemInvariantTest is ClinovaBase {
    SystemHandler internal handler;
    address[3] internal buyersArr;
    address[4] internal providersArr;
    address[2] internal verifiersArr;
    address internal dave = makeAddr("dave");
    address internal v2 = makeAddr("market-only-verifier");

    function setUp() public override {
        super.setUp();
        _eligible(dave);
        address buyer3 = makeAddr("buyer3");
        buyersArr = [buyer, buyer2, buyer3];
        providersArr = [alice, bob, dave, carol]; // carol: registered, unverified
        verifiersArr = [verifier, v2];
        vm.startPrank(admin);
        market.grantRole(market.VERIFIER_ROLE(), v2);
        // A buyer and a provider that also hold VERIFIER_ROLE: conflict-of-interest is attacked continuously.
        market.grantRole(market.VERIFIER_ROLE(), buyer);
        market.grantRole(market.VERIFIER_ROLE(), alice);
        vm.stopPrank();
        handler =
            new SystemHandler(market, admin, pauser, buyersArr, providersArr, verifiersArr, [CBC, MALARIA, GLUCOSE]);
        handler.setInitialMinted(_trackedSupply());
        _seedDeepStates();
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](29);
        (sel[0], sel[1], sel[2], sel[3]) =
        (
            SystemHandler.create.selector,
            SystemHandler.accept.selector,
            SystemHandler.start.selector,
            SystemHandler.submitProof.selector
        );
        (sel[4], sel[5], sel[6], sel[7]) =
        (
            SystemHandler.confirm.selector,
            SystemHandler.approve.selector,
            SystemHandler.reject.selector,
            SystemHandler.dispute.selector
        );
        (sel[8], sel[9], sel[10], sel[11]) =
        (
            SystemHandler.resolve.selector,
            SystemHandler.cancel.selector,
            SystemHandler.expire.selector,
            SystemHandler.closeUnreviewed.selector
        );
        (sel[12], sel[13], sel[14], sel[15]) =
        (
            SystemHandler.timeout.selector,
            SystemHandler.withdraw.selector,
            SystemHandler.providerDeactivate.selector,
            SystemHandler.providerActivate.selector
        );
        (sel[16], sel[17], sel[18], sel[19]) =
        (
            SystemHandler.providerRequestUnstake.selector,
            SystemHandler.providerWithdrawStake.selector,
            SystemHandler.providerDeposit.selector,
            SystemHandler.providerChurn.selector
        );
        (sel[20], sel[21], sel[22], sel[23]) =
        (
            SystemHandler.registryVerify.selector,
            SystemHandler.registryRevoke.selector,
            SystemHandler.toggleMarketVerifier.selector,
            SystemHandler.adminParams.selector
        );
        (sel[24], sel[25], sel[26], sel[27]) =
        (
            SystemHandler.togglePause.selector,
            SystemHandler.warp.selector,
            SystemHandler.donate.selector,
            SystemHandler.attack.selector
        );
        sel[28] = SystemHandler.providerRecover.selector;
        // Every action except setInitialMinted (a setup-only setter the fuzzer must never call).
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// Start every run with requests in deep states so short random sequences still exercise late transitions.
    function _seedDeepStates() internal {
        for (uint256 i = 0; i < 8; ++i) {
            handler.create(i, 1, 0, 10e6, 2 days, 5 days);
        }
        for (uint256 i = 0; i < 6; ++i) {
            handler.accept(i, i % 3); // alice, bob, dave
        }
        for (uint256 i = 0; i < 4; ++i) {
            handler.start(i);
        }
        handler.submitProof(0, false, 3);
        handler.submitProof(1, false, 3);
        handler.dispute(1, false); // buyer disputes an ACCEPTED/IN_SERVICE one
    }

    function _trackedSupply() internal view returns (uint256 t) {
        address[] memory holders = _holders();
        for (uint256 i = 0; i < holders.length; ++i) {
            t += usdc.balanceOf(holders[i]);
        }
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](23);
        uint256 k;
        for (uint256 i = 0; i < 3; ++i) {
            h[k++] = buyersArr[i];
            h[k++] = handler.coldOf(buyersArr[i]);
        }
        for (uint256 i = 0; i < 4; ++i) {
            h[k++] = providersArr[i];
            h[k++] = handler.coldOf(providersArr[i]);
        }
        h[k++] = address(escrow);
        h[k++] = address(registry);
        h[k++] = address(market);
        h[k++] = address(pos);
        h[k++] = address(rep);
        h[k++] = admin;
        h[k++] = pauser;
        h[k++] = verifier;
        h[k++] = v2;
    }

    // ------------------------------------------------------------------
    // A. Escrow conservation
    // ------------------------------------------------------------------

    /// funded == released + refunded + locked; balance == locked + credited + donations (exact).
    function invariant_A_EscrowConservation() public view {
        assertEq(handler.ghostFunded(), handler.ghostReleased() + handler.ghostRefunded() + escrow.totalLocked());
        assertEq(
            usdc.balanceOf(address(escrow)),
            escrow.totalLocked() + escrow.totalCredited() + handler.ghostEscrowDonations()
        );
        uint256 sumCredit;
        uint256 sumCredited;
        for (uint256 i = 0; i < 7; ++i) {
            address a = i < 3 ? buyersArr[i] : providersArr[i - 3];
            assertEq(escrow.credit(a) + handler.ghostWithdrawn(a), handler.ghostCredited(a), "per-account credit");
            sumCredit += escrow.credit(a);
            sumCredited += handler.ghostCredited(a);
        }
        assertEq(escrow.totalCredited(), sumCredit, "credit belongs only to parties");
        assertEq(sumCredited, handler.ghostReleased() + handler.ghostRefunded(), "every credit came from one outcome");
    }

    // ------------------------------------------------------------------
    // B. Provider stake conservation
    // ------------------------------------------------------------------

    function invariant_B_StakeConservation() public view {
        uint256 sum;
        for (uint256 i = 0; i < 4; ++i) {
            address p = providersArr[i];
            uint256 s = registry.getProvider(p).stake;
            assertEq(s, handler.ghostStakeIn(p) - handler.ghostStakeOut(p), "stake == deposited - withdrawn");
            sum += s;
        }
        assertEq(registry.totalStaked(), sum);
        assertEq(usdc.balanceOf(address(registry)), registry.totalStaked() + handler.ghostRegistryDonations());
    }

    /// activeJobs equals the marketplace's count of open obligations for every provider.
    function invariant_B_ActiveJobsMatchMarketplace() public view {
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(registry.getProvider(providersArr[i]).activeJobs, handler._liveJobsOf(providersArr[i]));
        }
    }

    // ------------------------------------------------------------------
    // C/D. Request <-> provider <-> escrow
    // ------------------------------------------------------------------

    function invariant_CD_RequestBindings() public view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            ClinovaTypes.Deposit memory d = escrow.getDeposit(id);
            ClinovaTypes.Job memory job = registry.getJob(id);
            // D: escrow mirrors the request
            assertEq(d.amount, r.price, "deposit == price");
            assertEq(d.payer, r.buyer, "payer == buyer");
            if (r.status == ClinovaTypes.Status.SETTLED) {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.RELEASED));
            } else if (ClinovaTypes.isTerminal(r.status)) {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.REFUNDED));
            } else {
                assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.FUNDED), "unfinalized => funded");
            }
            // C: one provider, bound identically everywhere
            if (job.status == ClinovaTypes.JobStatus.NONE) {
                assertEq(d.payee, address(0), "never accepted => no payee");
                assertEq(handler.acceptedBy(id), address(0), "never accepted => no provider recorded");
                assertTrue(
                    r.status == ClinovaTypes.Status.OPEN || r.status == ClinovaTypes.Status.CANCELLED
                        || r.status == ClinovaTypes.Status.EXPIRED,
                    "never accepted => OPEN/CANCELLED/EXPIRED"
                );
            } else {
                address p = handler.acceptedBy(id);
                assertEq(job.provider, p, "registry job == accepting provider");
                assertEq(r.provider, p, "request provider == accepting provider");
                assertEq(d.payee, p, "escrow payee == accepting provider");
            }
        }
    }

    // ------------------------------------------------------------------
    // E. Proof consistency
    // ------------------------------------------------------------------

    function invariant_E_ProofConsistency() public view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            ClinovaTypes.ServiceProof memory p = pos.getProof(id);
            if (p.status != ClinovaTypes.ProofStatus.NONE) {
                assertEq(p.provider, handler.acceptedBy(id), "proof provider == accepting provider");
                assertEq(p.proofHash, pos.computeProofHash(id, p.provider, p.evidenceCommitment), "bound hash");
                assertTrue(pos.evidenceUsed(p.provider, p.evidenceCommitment));
            }
            bool positive =
                p.status == ClinovaTypes.ProofStatus.APPROVED || p.status == ClinovaTypes.ProofStatus.BUYER_ACCEPTED;
            assertEq(r.status == ClinovaTypes.Status.SETTLED, positive, "SETTLED <=> positive acceptance");
            if (p.status == ClinovaTypes.ProofStatus.REJECTED) {
                assertTrue(r.status == ClinovaTypes.Status.DISPUTED || r.status == ClinovaTypes.Status.REFUNDED);
            }
            if (p.status == ClinovaTypes.ProofStatus.UNRESOLVED) {
                assertEq(uint8(r.status), uint8(ClinovaTypes.Status.REFUNDED));
            }
            if (ClinovaTypes.isTerminal(r.status)) assertTrue(p.status != ClinovaTypes.ProofStatus.SUBMITTED);
            if (r.status == ClinovaTypes.Status.COMPLETED) {
                assertEq(uint8(p.status), uint8(ClinovaTypes.ProofStatus.SUBMITTED));
            }
        }
    }

    // ------------------------------------------------------------------
    // F. Reputation consistency
    // ------------------------------------------------------------------

    function invariant_F_ReputationConsistency() public view {
        uint256 settled;
        uint256[4] memory settledValue;
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            assertEq(rep.outcomeRecorded(id), registry.getJob(id).status == ClinovaTypes.JobStatus.CLOSED);
            if (r.status == ClinovaTypes.Status.SETTLED) {
                settled++;
                for (uint256 p = 0; p < 4; ++p) {
                    if (r.provider == providersArr[p]) settledValue[p] += r.price;
                }
            }
        }
        uint256 successes;
        for (uint256 p = 0; p < 4; ++p) {
            address a = providersArr[p];
            ClinovaTypes.Reputation memory rr = rep.getReputation(a);
            assertEq(rr.completedJobs, handler.ghostCompleted(a), "completedJobs");
            assertEq(rr.successfulJobs, handler.ghostSuccessful(a), "successfulJobs");
            assertEq(rr.failedJobs, handler.ghostFailed(a), "failedJobs");
            assertEq(rr.disputes, handler.ghostDisputes(a), "disputes");
            assertEq(handler.ghostPaidToProvider(a), settledValue[p], "success <=> actual payment to that provider");
            if (!handler.everAccepted(a)) {
                assertEq(rr.completedJobs + rr.successfulJobs + rr.failedJobs + rr.disputes, 0, "never accepted");
            }
            successes += rr.successfulJobs;
        }
        assertEq(successes, settled);
    }

    // ------------------------------------------------------------------
    // Global
    // ------------------------------------------------------------------

    function invariant_G_GlobalConservation() public view {
        assertEq(_trackedSupply(), handler.ghostMinted(), "no token created or destroyed");
        assertEq(usdc.balanceOf(address(market)) + usdc.balanceOf(address(pos)) + usdc.balanceOf(address(rep)), 0);
        assertEq(escrow.credit(admin) + escrow.credit(verifier) + escrow.credit(v2) + escrow.credit(pauser), 0);
    }

    function invariant_H_NoViolations() public view {
        assertFalse(handler.violation(), handler.violationReason());
        assertTrue(handler.terminalsIntact(), "a terminal request, its escrow or its final proof changed");
    }

    /// From ANY reachable state: both contracts paused, every marketplace verifier revoked, no admin action.
    /// Every request terminates, every credit withdraws, every provider exits with exactly its stake.
    function invariant_I_NoPermanentLock() public {
        uint256 snap = vm.snapshotState();
        vm.startPrank(pauser);
        if (!market.paused()) market.pause();
        if (!registry.paused()) registry.pause();
        vm.stopPrank();
        bytes32 role = market.VERIFIER_ROLE();
        address[4] memory vs = [verifier, v2, buyer, alice];
        vm.startPrank(admin);
        for (uint256 i = 0; i < 4; ++i) {
            if (market.hasRole(role, vs[i])) market.revokeRole(role, vs[i]);
        }
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 200 days);
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            if (r.status == ClinovaTypes.Status.OPEN) {
                market.expireRequest(id);
            } else if (r.status == ClinovaTypes.Status.ACCEPTED || r.status == ClinovaTypes.Status.IN_SERVICE) {
                vm.prank(r.provider);
                market.expireRequest(id);
            } else if (r.status == ClinovaTypes.Status.COMPLETED) {
                market.closeUnreviewed(id);
            } else if (r.status == ClinovaTypes.Status.DISPUTED) {
                market.resolveDisputeByTimeout(id);
            }
            assertTrue(ClinovaTypes.isTerminal(market.getRequest(id).status));
        }
        for (uint256 i = 0; i < 7; ++i) {
            address a = i < 3 ? buyersArr[i] : providersArr[i - 3];
            if (escrow.credit(a) > 0) {
                vm.prank(a);
                escrow.withdraw();
            }
        }
        for (uint256 i = 0; i < 4; ++i) {
            address p = providersArr[i];
            ClinovaTypes.Provider memory pr = registry.getProvider(p);
            assertEq(pr.activeJobs, 0);
            if (pr.stake == 0) continue;
            vm.startPrank(p);
            if (pr.unstakeAvailableAt == 0) registry.requestUnstake();
            vm.warp(vm.getBlockTimestamp() + 31 days);
            uint256 before = usdc.balanceOf(p);
            registry.withdrawStake();
            vm.stopPrank();
            assertEq(usdc.balanceOf(p) - before, pr.stake, "exactly its own stake");
        }
        assertEq(escrow.totalLocked() + escrow.totalCredited(), 0);
        assertEq(usdc.balanceOf(address(escrow)), handler.ghostEscrowDonations());
        assertEq(registry.totalStaked(), 0);
        assertEq(usdc.balanceOf(address(registry)), handler.ghostRegistryDonations());
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------
    // Non-vacuity of the RANDOM driver (no scripted steps): pseudo-random action sequences must reach every
    // important protocol state. Complements the campaign's per-action success metrics (calls - reverts).
    // ------------------------------------------------------------------

    function _runRandom(uint256 seed, uint256 rounds) internal {
        for (uint256 i = 0; i < rounds; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, i)));
            (bool ok,) = address(handler).call(_randomAction(s % 27, s));
            ok;
        }
    }

    function _probe(bool[12] memory seen) internal view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ClinovaTypes.ServiceRequest memory r = market.getRequest(id);
            ClinovaTypes.ProofStatus ps = pos.proofStatus(id);
            ClinovaTypes.EscrowState es = escrow.getDeposit(id).state;
            if (es == ClinovaTypes.EscrowState.RELEASED) seen[0] = true;
            if (es == ClinovaTypes.EscrowState.REFUNDED) seen[1] = true;
            if (ps == ClinovaTypes.ProofStatus.APPROVED) seen[2] = true;
            if (ps == ClinovaTypes.ProofStatus.REJECTED) seen[3] = true;
            if (ps == ClinovaTypes.ProofStatus.BUYER_ACCEPTED) seen[4] = true;
            if (ps == ClinovaTypes.ProofStatus.UNRESOLVED) seen[5] = true;
            if (r.disputedFrom != ClinovaTypes.Status.NONE && ClinovaTypes.isTerminal(r.status)) seen[6] = true;
            if (r.status == ClinovaTypes.Status.EXPIRED && registry.getJob(id).provider != address(0)) seen[7] = true;
            if (r.status == ClinovaTypes.Status.CANCELLED) seen[8] = true;
        }
        for (uint256 p = 0; p < 4; ++p) {
            if (rep.getReputation(providersArr[p]).failedJobs > 0) seen[9] = true;
            if (handler.ghostStakeOut(providersArr[p]) > 0) seen[10] = true;
            if (handler.ghostWithdrawn(providersArr[p]) > 0) seen[11] = true;
        }
    }

    function _assertAllInvariants() internal {
        invariant_A_EscrowConservation();
        invariant_B_StakeConservation();
        invariant_B_ActiveJobsMatchMarketplace();
        invariant_CD_RequestBindings();
        invariant_E_ProofConsistency();
        invariant_F_ReputationConsistency();
        invariant_G_GlobalConservation();
        invariant_H_NoViolations();
        invariant_I_NoPermanentLock();
    }

    /// Three independent pseudo-random campaigns from the same start; together they must reach every state, and
    /// every invariant must hold at the end of each.
    function test_RandomCampaignsReachEveryState() public {
        bool[12] memory seen;
        uint256 snap = vm.snapshotState();
        for (uint256 seed = 1; seed <= 3; ++seed) {
            _runRandom(seed, 450);
            _probe(seen);
            _assertAllInvariants();
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
        string[12] memory names = [
            "escrow released",
            "escrow refunded",
            "proof approved",
            "proof rejected",
            "proof buyer-accepted",
            "proof unresolved",
            "dispute resolved/timed out",
            "accepted job expired (fault)",
            "request cancelled",
            "failedJobs recorded",
            "stake withdrawn",
            "provider payment withdrawn"
        ];
        for (uint256 k = 0; k < 12; ++k) {
            assertTrue(seen[k], names[k]);
        }
    }

    /// Arbitrary random campaigns (fuzzed seed, 500 steps) preserve every invariant, including no-permanent-lock.
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_RandomCampaignKeepsInvariants(uint256 seed) public {
        _runRandom(seed, 500);
        _assertAllInvariants();
    }

    function _randomAction(uint256 which, uint256 s) internal view returns (bytes memory) {
        uint256 a = s >> 8;
        uint256 b = s >> 40;
        uint8 c = uint8(s >> 72);
        bool f = (s >> 80) & 1 == 1;
        if (which == 0 || which == 1) {
            return abi.encodeCall(SystemHandler.create, (a, b, c, uint128(a), uint64(b), uint64(a >> 3)));
        }
        if (which == 2 || which == 3) return abi.encodeCall(SystemHandler.accept, (a, b));
        if (which == 4) return abi.encodeCall(SystemHandler.start, (a));
        if (which == 5) return abi.encodeCall(SystemHandler.submitProof, (a, f, c));
        if (which == 6) return abi.encodeCall(SystemHandler.confirm, (a));
        if (which == 7) return abi.encodeCall(SystemHandler.approve, (a, b));
        if (which == 8) return abi.encodeCall(SystemHandler.reject, (a, b));
        if (which == 9) return abi.encodeCall(SystemHandler.dispute, (a, f));
        if (which == 10) return abi.encodeCall(SystemHandler.resolve, (a, c, b));
        if (which == 11) return abi.encodeCall(SystemHandler.cancel, (a));
        if (which == 12) return abi.encodeCall(SystemHandler.expire, (a, f, b % 2 == 0));
        if (which == 13) return abi.encodeCall(SystemHandler.closeUnreviewed, (a, f));
        if (which == 14) return abi.encodeCall(SystemHandler.timeout, (a, f));
        if (which == 15) return abi.encodeCall(SystemHandler.withdraw, (a, f));
        if (which == 16) return abi.encodeCall(SystemHandler.providerDeactivate, (a));
        if (which == 17) return abi.encodeCall(SystemHandler.providerActivate, (a));
        if (which == 18) return abi.encodeCall(SystemHandler.providerRequestUnstake, (a));
        if (which == 19) return abi.encodeCall(SystemHandler.providerWithdrawStake, (a, f));
        if (which == 20) return abi.encodeCall(SystemHandler.providerDeposit, (a, b));
        if (which == 21) return abi.encodeCall(SystemHandler.providerChurn, (a, c, b));
        if (which == 22) {
            return
                f
                    ? abi.encodeCall(SystemHandler.registryVerify, (a))
                    : abi.encodeCall(SystemHandler.registryRevoke, (a));
        }
        if (which == 23) {
            return f
                ? abi.encodeCall(SystemHandler.toggleMarketVerifier, (a))
                : abi.encodeCall(SystemHandler.adminParams, (c, b));
        }
        if (which == 24) {
            return f
                ? abi.encodeCall(SystemHandler.togglePause, (b % 2 == 0, c))
                : abi.encodeCall(SystemHandler.donate, (a, f));
        }
        if (which == 25 && f) return abi.encodeCall(SystemHandler.attack, (a, b));
        if (which == 26) return abi.encodeCall(SystemHandler.providerRecover, (a));
        return abi.encodeCall(SystemHandler.warp, (a));
    }
}
