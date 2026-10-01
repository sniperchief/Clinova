// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ClinovaTypes} from "./libraries/ClinovaTypes.sol";
import {IServiceMarketplace} from "./interfaces/IServiceMarketplace.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IClinovaEscrow} from "./interfaces/IClinovaEscrow.sol";
import {IProofOfService} from "./interfaces/IProofOfService.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";

/// @title ServiceMarketplace
/// @notice Fixed-price diagnostic service requests with USDC escrow. The only orchestrator of the request
///         state machine (docs/contract-spec.md §1). Holds no funds: buyer USDC goes straight to ClinovaEscrow.
/// @dev Authority over other modules is narrow and per-request:
///        - ProviderRegistry: recordJobAccepted / recordJobClosed for (requestId, msg.sender-derived provider);
///        - ClinovaEscrow: lock / assignPayee / release / refund for one request id.
///        - ProofOfService / ReputationRegistry: per-request writes; neither has any permission here.
///      Payment always needs positive acceptance (buyer, or a non-party verifier). Every non-terminal state has an
///      exit that needs neither the admin nor a verifier.
contract ServiceMarketplace is IServiceMarketplace, AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint64 public constant MIN_ACCEPT_WINDOW = 1 hours;
    uint64 public constant MAX_ACCEPT_WINDOW = 7 days;
    uint64 public constant MIN_SERVICE_WINDOW = 6 hours;
    uint64 public constant MAX_SERVICE_WINDOW = 30 days;

    uint256 public constant MIN_PRICE_FLOOR = 1e6; // 1 USDC
    uint256 public constant MIN_PRICE_CEILING = 10_000e6; // 10,000 USDC
    uint32 public constant MIN_REVIEW_PERIOD = 1 days;
    uint32 public constant MAX_REVIEW_PERIOD = 14 days;
    uint32 public constant MIN_DISPUTE_PERIOD = 3 days;
    uint32 public constant MAX_DISPUTE_PERIOD = 60 days;

    bytes32 public constant MIN_PRICE_KEY = "MIN_PRICE";
    bytes32 public constant REVIEW_PERIOD_KEY = "REVIEW_PERIOD";
    bytes32 public constant DISPUTE_PERIOD_KEY = "DISPUTE_PERIOD";

    /// @dev Reason recorded on a SUBMITTED proof when a verifier resolves its dispute with a refund.
    bytes32 public constant DISPUTE_REFUND_REASON = keccak256("CLINOVA_DISPUTE_REFUND");

    IProviderRegistry public immutable registry;
    IClinovaEscrow public immutable escrow;
    IProofOfService public immutable proofOfService;
    IReputationRegistry public immutable reputation;
    IERC20 public immutable usdc;

    uint256 public minPrice;
    uint32 public reviewPeriod;
    uint32 public disputePeriod;
    uint256 public nextRequestId = 1; // id 0 is never valid

    mapping(uint256 id => ClinovaTypes.ServiceRequest) private _requests;

    constructor(
        address admin,
        uint48 adminTransferDelay,
        IProviderRegistry registry_,
        IClinovaEscrow escrow_,
        IProofOfService proofOfService_,
        IReputationRegistry reputation_,
        uint256 minPrice_,
        uint32 reviewPeriod_,
        uint32 disputePeriod_
    ) AccessControlDefaultAdminRules(adminTransferDelay, admin) {
        if (
            address(registry_) == address(0) || address(escrow_) == address(0) || address(proofOfService_) == address(0)
                || address(reputation_) == address(0)
        ) {
            revert ZeroAddress();
        }
        // Every module must have been deployed with this contract as its immutable marketplace, the registry and
        // escrow must share one token, and reputation must read the same registry and proof module.
        if (
            registry_.marketplace() != address(this) || escrow_.marketplace() != address(this)
                || proofOfService_.marketplace() != address(this) || reputation_.marketplace() != address(this)
        ) {
            revert InvalidWiring();
        }
        if (address(registry_.usdc()) != address(escrow_.usdc())) revert InvalidWiring();
        if (
            address(reputation_.registry()) != address(registry_)
                || address(reputation_.proofOfService()) != address(proofOfService_)
        ) {
            revert InvalidWiring();
        }
        registry = registry_;
        escrow = escrow_;
        proofOfService = proofOfService_;
        reputation = reputation_;
        usdc = escrow_.usdc();
        _setMinPrice(minPrice_);
        _setReviewPeriod(reviewPeriod_);
        _setDisputePeriod(disputePeriod_);
    }

    // ------------------------------------------------------------------
    // Buyer
    // ------------------------------------------------------------------

    /// @notice Create and fund a request in one transaction. Requires USDC approval of `price` to this contract.
    /// @dev Funding is atomic with creation, so no request exists in an unfunded state and double funding is
    ///      impossible. Tokens move buyer -> escrow directly; escrow independently checks they arrived.
    function createRequest(
        address directedProvider,
        bytes32 serviceType,
        bytes32 locationHash,
        uint128 price,
        uint64 acceptDeadline,
        uint64 serviceDeadline
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        if (serviceType == bytes32(0)) revert InvalidServiceType();
        if (locationHash == bytes32(0)) revert InvalidHash();
        if (directedProvider == msg.sender) revert BuyerCannotAccept();
        uint256 floor = minPrice;
        if (price < floor) revert PriceTooLow(price, floor);
        _validateDeadlines(acceptDeadline, serviceDeadline);

        id = nextRequestId++;
        ClinovaTypes.ServiceRequest storage r = _requests[id];
        r.buyer = msg.sender;
        r.createdAt = block.timestamp.toUint64();
        r.status = ClinovaTypes.Status.OPEN;
        r.provider = directedProvider;
        r.acceptDeadline = acceptDeadline;
        r.serviceType = serviceType;
        r.locationHash = locationHash;
        r.price = price;
        r.serviceDeadline = serviceDeadline;
        r.reviewPeriod = reviewPeriod;
        r.disputePeriod = disputePeriod;
        emit ServiceRequestCreated(
            id, msg.sender, directedProvider, serviceType, locationHash, price, acceptDeadline, serviceDeadline
        );

        _fund(id, price);
    }

    /// @notice OPEN -> CANCELLED. Full refund is credited to the buyer.
    function cancelRequest(uint256 id) external {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.OPEN);
        if (msg.sender != r.buyer) revert NotBuyer(id);
        r.status = ClinovaTypes.Status.CANCELLED;
        emit ServiceRequestCancelled(id, r.price);
        _escrowRefund(id, r.price);
    }

    /// @notice COMPLETED -> SETTLED. The payer accepts the completion and releases payment to the bound provider.
    function confirmCompletion(uint256 id) external {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.COMPLETED);
        if (msg.sender != r.buyer) revert NotBuyer(id);
        _settle(id, r, SettlementPath.BUYER_CONFIRMED);
        proofOfService.markBuyerAccepted(id, msg.sender); // SUBMITTED -> BUYER_ACCEPTED (reverts otherwise)
    }

    // ------------------------------------------------------------------
    // Provider (identity is always msg.sender)
    // ------------------------------------------------------------------

    /// @notice OPEN -> ACCEPTED. The accepting provider is msg.sender; eligibility is enforced by the registry.
    function acceptRequest(uint256 id) external whenNotPaused {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.OPEN);
        _requireNotPast(r.acceptDeadline);
        if (msg.sender == r.buyer) revert BuyerCannotAccept();
        if (r.provider != address(0) && r.provider != msg.sender) revert NotAssignedProvider(id);

        r.provider = msg.sender;
        r.status = ClinovaTypes.Status.ACCEPTED;
        emit ServiceRequestAccepted(id, msg.sender);

        registry.recordJobAccepted(id, msg.sender, r.serviceType); // reverts unless msg.sender is eligible
        escrow.assignPayee(id, msg.sender); // reverts unless the deposit is FUNDED; binds the only payee
    }

    /// @notice ACCEPTED -> IN_SERVICE (e.g. sample collected).
    function startService(uint256 id) external {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.ACCEPTED);
        _requireAssignedProvider(id, r);
        _requireNotPast(r.serviceDeadline);
        r.status = ClinovaTypes.Status.IN_SERVICE;
        emit ServiceRequestStarted(id, msg.sender);
    }

    /// @notice IN_SERVICE -> COMPLETED with a salted evidence commitment; or, while DISPUTED from
    ///         ACCEPTED/IN_SERVICE with no proof yet, attach it as dispute evidence (status unchanged).
    /// @dev The proof is recorded in ProofOfService (source of truth), which binds it to this request and to
    ///      msg.sender, rejects a second proof for the request and a reused commitment, and returns the bound hash.
    function submitProof(uint256 id, bytes32 evidenceCommitment) external {
        ClinovaTypes.ServiceRequest storage r = _requests[id];
        ClinovaTypes.Status status = r.status;
        bool intoDispute = status == ClinovaTypes.Status.DISPUTED
            && (r.disputedFrom == ClinovaTypes.Status.ACCEPTED || r.disputedFrom == ClinovaTypes.Status.IN_SERVICE);
        if (status != ClinovaTypes.Status.IN_SERVICE && !intoDispute) revert InvalidStatus(id, status);
        _requireAssignedProvider(id, r);
        _requireNotPast(r.serviceDeadline);

        uint64 reviewDeadline = 0; // only meaningful when completing
        if (!intoDispute) {
            reviewDeadline = block.timestamp.toUint64() + r.reviewPeriod;
            r.reviewDeadline = reviewDeadline;
            r.status = ClinovaTypes.Status.COMPLETED;
        }
        // Trusted immutable module; it only makes view calls back into this contract.
        bytes32 proofHash = proofOfService.submit(id, msg.sender, evidenceCommitment);
        if (intoDispute) {
            // forge-lint: disable-next-line(reentrancy-events)
            emit DisputeEvidenceSubmitted(id, msg.sender, proofHash);
        } else {
            // forge-lint: disable-next-line(reentrancy-events)
            emit ServiceRequestCompleted(id, msg.sender, proofHash, reviewDeadline);
        }
    }

    // ------------------------------------------------------------------
    // Parties
    // ------------------------------------------------------------------

    /// @notice ACCEPTED/IN_SERVICE -> DISPUTED (buyer or provider, before serviceDeadline), or
    ///         COMPLETED -> DISPUTED (buyer only, within the review window).
    function openDispute(uint256 id, bytes32 reasonHash) external {
        ClinovaTypes.ServiceRequest storage r = _requests[id];
        ClinovaTypes.Status status = r.status;
        if (status == ClinovaTypes.Status.ACCEPTED || status == ClinovaTypes.Status.IN_SERVICE) {
            if (msg.sender != r.buyer && msg.sender != r.provider) revert NotParty(id);
            _requireNotPast(r.serviceDeadline);
        } else if (status == ClinovaTypes.Status.COMPLETED) {
            if (msg.sender != r.buyer) revert NotBuyer(id);
            _requireNotPast(r.reviewDeadline);
        } else {
            revert InvalidStatus(id, status);
        }
        _toDisputed(id, r, reasonHash);
    }

    /// @notice OPEN -> EXPIRED (anyone, after acceptDeadline), or ACCEPTED/IN_SERVICE -> EXPIRED
    ///         (buyer or assigned provider, after serviceDeadline). The refund always goes to the buyer.
    function expireRequest(uint256 id) external {
        ClinovaTypes.ServiceRequest storage r = _requests[id];
        ClinovaTypes.Status status = r.status;
        if (status == ClinovaTypes.Status.OPEN) {
            _requirePast(r.acceptDeadline);
            r.status = ClinovaTypes.Status.EXPIRED;
            emit ServiceRequestExpired(id, msg.sender, status, r.price);
            _escrowRefund(id, r.price);
        } else if (status == ClinovaTypes.Status.ACCEPTED || status == ClinovaTypes.Status.IN_SERVICE) {
            if (msg.sender != r.buyer && msg.sender != r.provider) revert NotParty(id);
            _requirePast(r.serviceDeadline);
            r.status = ClinovaTypes.Status.EXPIRED;
            emit ServiceRequestExpired(id, msg.sender, status, r.price);
            _escrowRefund(id, r.price);
            registry.recordJobClosed(id, r.provider);
            reputation.recordOutcome(id, true); // missed its own service deadline
        } else {
            revert InvalidStatus(id, status);
        }
    }

    // ------------------------------------------------------------------
    // Anyone: time-gated liveness exits
    // ------------------------------------------------------------------

    /// @notice COMPLETED -> REFUNDED when nobody (buyer or verifier) reviewed the completion by `reviewDeadline`.
    /// @dev Payment requires positive acceptance (buyer confirmation, verifier approval or a PROVIDER_WINS
    ///      resolution), so an unreviewed claim is never paid. Funds return to the payer, the proof becomes
    ///      UNRESOLVED and no fault is recorded: this is a liveness exit, not a judgement.
    function closeUnreviewed(uint256 id) external {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.COMPLETED);
        _requirePast(r.reviewDeadline);
        emit CompletionClosedUnreviewed(id, msg.sender);
        _refundAccepted(id, r, false);
        proofOfService.markUnresolved(id);
    }

    /// @notice DISPUTED -> REFUNDED when no verifier has resolved the dispute by its deadline.
    /// @dev Not a finding of fault: the escrow's release condition was never established, so funds return to
    ///      the payer and the outcome is recorded as unresolved (DisputeTimedOut).
    function resolveDisputeByTimeout(uint256 id) external {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.DISPUTED);
        _requirePast(r.disputeDeadline);
        emit DisputeTimedOut(id, msg.sender);
        _refundAccepted(id, r, false);
        if (proofOfService.proofStatus(id) == ClinovaTypes.ProofStatus.SUBMITTED) proofOfService.markUnresolved(id);
    }

    // ------------------------------------------------------------------
    // Verifier (never a party to the request)
    // ------------------------------------------------------------------

    /// @notice COMPLETED -> SETTLED when a verifier approves the proof (ProofOfService: SUBMITTED -> APPROVED).
    ///         Allowed until the completion is closed as unreviewed.
    function approveProof(uint256 id) external onlyRole(VERIFIER_ROLE) {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.COMPLETED);
        _requireNotParty(r);
        _settle(id, r, SettlementPath.VERIFIER_APPROVED);
        proofOfService.approve(id, msg.sender); // SUBMITTED -> APPROVED (independently re-checks the verifier)
    }

    /// @notice COMPLETED -> DISPUTED when a verifier rejects the proof (ProofOfService: SUBMITTED -> REJECTED).
    ///         A rejected proof is final: the dispute can only end in a refund (with or without provider fault).
    function rejectProof(uint256 id, bytes32 reasonHash) external onlyRole(VERIFIER_ROLE) {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.COMPLETED);
        _requireNotParty(r);
        _toDisputed(id, r, reasonHash); // rejects a zero reasonHash
        proofOfService.reject(id, msg.sender, reasonHash); // SUBMITTED -> REJECTED (independently re-checks)
    }

    /// @notice DISPUTED -> SETTLED (PROVIDER_WINS; requires a SUBMITTED proof, which becomes APPROVED) or REFUNDED
    ///         (a SUBMITTED proof becomes REJECTED; the fault flag goes to reputation).
    ///         Available until someone executes the timeout, including after the dispute deadline.
    function resolveDispute(uint256 id, ClinovaTypes.Resolution resolution) external onlyRole(VERIFIER_ROLE) {
        ClinovaTypes.ServiceRequest storage r = _requireStatus(id, ClinovaTypes.Status.DISPUTED);
        _requireNotParty(r);
        emit DisputeResolved(id, msg.sender, resolution);
        ClinovaTypes.ProofStatus proof = proofOfService.proofStatus(id);
        if (resolution == ClinovaTypes.Resolution.PROVIDER_WINS) {
            // Needs a proof that is still under review: never NONE, never an already-REJECTED proof.
            if (proof != ClinovaTypes.ProofStatus.SUBMITTED) revert ProofNotApprovable(id, proof);
            _settle(id, r, SettlementPath.DISPUTE_RESOLVED);
            proofOfService.approve(id, msg.sender);
        } else {
            _refundAccepted(id, r, resolution == ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
            if (proof == ClinovaTypes.ProofStatus.SUBMITTED) {
                proofOfService.reject(id, msg.sender, DISPUTE_REFUND_REASON);
            }
        }
    }

    // ------------------------------------------------------------------
    // Admin (bounded; affects future requests only) / pauser
    // ------------------------------------------------------------------

    function setMinPrice(uint256 newMinPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMinPrice(newMinPrice);
    }

    function setReviewPeriod(uint32 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setReviewPeriod(newPeriod);
    }

    function setDisputePeriod(uint32 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDisputePeriod(newPeriod);
    }

    /// @notice Blocks createRequest and acceptRequest only. In-flight lifecycle steps and all exits stay open.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getRequest(uint256 id) external view returns (ClinovaTypes.ServiceRequest memory) {
        return _requests[id];
    }

    // ------------------------------------------------------------------
    // Internal: transitions
    // ------------------------------------------------------------------

    /// @dev Pull exactly `amount` from msg.sender straight into escrow, then have escrow record it.
    function _fund(uint256 id, uint256 amount) internal {
        emit ServiceRequestFunded(id, msg.sender, amount);
        address escrowAddr = address(escrow);
        uint256 balanceBefore = usdc.balanceOf(escrowAddr);
        usdc.safeTransferFrom(msg.sender, escrowAddr, amount);
        uint256 received = usdc.balanceOf(escrowAddr) - balanceBefore;
        if (received != amount) revert TransferAmountMismatch(amount, received);
        escrow.lock(id, msg.sender, amount);
    }

    function _toDisputed(uint256 id, ClinovaTypes.ServiceRequest storage r, bytes32 reasonHash) internal {
        if (reasonHash == bytes32(0)) revert InvalidHash();
        ClinovaTypes.Status from = r.status;
        uint64 deadline = block.timestamp.toUint64() + r.disputePeriod;
        r.disputedFrom = from;
        r.disputeDeadline = deadline;
        r.status = ClinovaTypes.Status.DISPUTED;
        emit ServiceRequestDisputed(id, msg.sender, reasonHash, from, deadline);
    }

    /// @dev -> SETTLED: escrow pays only the payee it bound at acceptance; the registry job is closed for
    ///      exactly the provider stored in the request.
    function _settle(uint256 id, ClinovaTypes.ServiceRequest storage r, SettlementPath path) internal {
        r.status = ClinovaTypes.Status.SETTLED;
        emit ServiceRequestSettled(id, r.provider, r.price, path);
        _escrowRelease(id, r.price); // pays the payee bound at acceptance
        registry.recordJobClosed(id, r.provider);
        reputation.recordOutcome(id, false);
    }

    /// @dev -> REFUNDED for a request that had been accepted (closes the provider's job, records the outcome).
    function _refundAccepted(uint256 id, ClinovaTypes.ServiceRequest storage r, bool providerAtFault) internal {
        r.status = ClinovaTypes.Status.REFUNDED;
        emit ServiceRequestRefunded(id, r.buyer, r.price);
        _escrowRefund(id, r.price);
        registry.recordJobClosed(id, r.provider);
        reputation.recordOutcome(id, providerAtFault);
    }

    /// @dev Defense in depth: escrow must move exactly the request price (its deposit was locked at that amount).
    function _escrowRelease(uint256 id, uint256 price) internal {
        uint256 moved = escrow.release(id);
        if (moved != price) revert EscrowAmountMismatch(id, price, moved);
    }

    function _escrowRefund(uint256 id, uint256 price) internal {
        uint256 moved = escrow.refund(id);
        if (moved != price) revert EscrowAmountMismatch(id, price, moved);
    }

    // ------------------------------------------------------------------
    // Internal: checks
    // ------------------------------------------------------------------

    function _requireStatus(uint256 id, ClinovaTypes.Status expected)
        internal
        view
        returns (ClinovaTypes.ServiceRequest storage r)
    {
        r = _requests[id];
        if (r.status != expected) revert InvalidStatus(id, r.status);
    }

    function _requireAssignedProvider(uint256 id, ClinovaTypes.ServiceRequest storage r) internal view {
        if (msg.sender != r.provider) revert NotAssignedProvider(id);
    }

    function _requireNotParty(ClinovaTypes.ServiceRequest storage r) internal view {
        if (msg.sender == r.buyer || msg.sender == r.provider) revert ConflictOfInterest(msg.sender);
    }

    /// @dev Action allowed while now <= deadline. Deadlines are hours/days-scale (docs/arbitrum-research.md).
    function _requireNotPast(uint64 deadline) internal view {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
    }

    /// @dev Exit allowed only once now > deadline (strictly after).
    function _requirePast(uint64 deadline) internal view {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= deadline) revert DeadlineNotPassed(deadline);
    }

    function _validateDeadlines(uint64 acceptDeadline, uint64 serviceDeadline) internal view {
        // Input validation against hour-scale bounds; sequencer timestamp skew is immaterial here.
        uint256 nowTs = block.timestamp;
        uint256 a = acceptDeadline;
        uint256 s = serviceDeadline;
        // forge-lint: disable-next-line(block-timestamp)
        if (a < nowTs + MIN_ACCEPT_WINDOW || a > nowTs + MAX_ACCEPT_WINDOW) revert InvalidDeadlines();
        if (s < a + MIN_SERVICE_WINDOW || s > a + MAX_SERVICE_WINDOW) revert InvalidDeadlines();
    }

    // ------------------------------------------------------------------
    // Internal: parameters
    // ------------------------------------------------------------------

    function _setMinPrice(uint256 v) internal {
        if (v < MIN_PRICE_FLOOR || v > MIN_PRICE_CEILING) revert ParameterOutOfBounds(MIN_PRICE_KEY, v);
        emit ParameterUpdated(MIN_PRICE_KEY, minPrice, v);
        minPrice = v;
    }

    function _setReviewPeriod(uint32 v) internal {
        if (v < MIN_REVIEW_PERIOD || v > MAX_REVIEW_PERIOD) revert ParameterOutOfBounds(REVIEW_PERIOD_KEY, v);
        emit ParameterUpdated(REVIEW_PERIOD_KEY, reviewPeriod, v);
        reviewPeriod = v;
    }

    function _setDisputePeriod(uint32 v) internal {
        if (v < MIN_DISPUTE_PERIOD || v > MAX_DISPUTE_PERIOD) revert ParameterOutOfBounds(DISPUTE_PERIOD_KEY, v);
        emit ParameterUpdated(DISPUTE_PERIOD_KEY, disputePeriod, v);
        disputePeriod = v;
    }
}
