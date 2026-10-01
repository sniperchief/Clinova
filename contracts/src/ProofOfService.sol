// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ClinovaTypes} from "./libraries/ClinovaTypes.sol";
import {IProofOfService} from "./interfaces/IProofOfService.sol";
import {IServiceMarketplace} from "./interfaces/IServiceMarketplace.sol";

/// @title ProofOfService
/// @notice Records a cryptographic commitment to offchain service evidence per request, and the outcome of its
///         review. Clinova records a commitment to service evidence and uses an authorized verification process
///         to decide whether that evidence supports completion; the chain itself does not verify medical services.
/// @dev - Only the immutable marketplace can write. This contract holds no funds and has no admin, and it has no
///        permission of any kind on the marketplace, so it cannot trigger settlement.
///      - Defense in depth: every write re-reads the marketplace request and checks the provider, buyer and
///        verifier relationships instead of trusting the arguments.
///      - proofHash is computed here, binding the provider's salted evidence commitment to this chain, this
///        contract, the request and the provider. It can never be read as belonging to another request/provider.
///      - Replay protection: a provider can use a given evidence commitment only once, across all its requests.
///        It is scoped per provider so nobody can burn another provider's commitment.
contract ProofOfService is IProofOfService {
    using SafeCast for uint256;

    bytes32 public constant PROOF_DOMAIN = keccak256("CLINOVA_PROOF_V1");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    address public immutable marketplace;

    mapping(uint256 requestId => ClinovaTypes.ServiceProof) private _proofs;
    mapping(address provider => mapping(bytes32 evidenceCommitment => bool)) public evidenceUsed;

    modifier onlyMarketplace() {
        if (msg.sender != marketplace) revert OnlyMarketplace();
        _;
    }

    constructor(address marketplace_) {
        if (marketplace_ == address(0)) revert ZeroAddress();
        marketplace = marketplace_;
    }

    // ------------------------------------------------------------------
    // Marketplace only
    // ------------------------------------------------------------------

    /// @notice NONE -> SUBMITTED. One proof per request; no replacement.
    function submit(uint256 requestId, address provider, bytes32 evidenceCommitment)
        external
        onlyMarketplace
        returns (bytes32 proofHash)
    {
        if (evidenceCommitment == bytes32(0)) revert InvalidCommitment();
        ClinovaTypes.ServiceProof storage p = _proofs[requestId];
        if (p.status != ClinovaTypes.ProofStatus.NONE) revert ProofAlreadySubmitted(requestId);
        ClinovaTypes.ServiceRequest memory r = _request(requestId);
        if (provider == address(0) || r.provider != provider) revert ProviderMismatch(requestId, r.provider, provider);
        if (evidenceUsed[provider][evidenceCommitment]) revert EvidenceAlreadyUsed(provider, evidenceCommitment);

        proofHash = computeProofHash(requestId, provider, evidenceCommitment);
        uint64 nowTs = block.timestamp.toUint64();
        evidenceUsed[provider][evidenceCommitment] = true;
        p.provider = provider;
        p.submittedAt = nowTs;
        p.status = ClinovaTypes.ProofStatus.SUBMITTED;
        p.evidenceCommitment = evidenceCommitment;
        p.proofHash = proofHash;
        emit ProofSubmitted(requestId, provider, proofHash, evidenceCommitment, nowTs);
    }

    /// @notice SUBMITTED -> APPROVED by an independent verifier.
    function approve(uint256 requestId, address verifier) external onlyMarketplace {
        ClinovaTypes.ServiceProof storage p = _requireSubmitted(requestId);
        _requireIndependentVerifier(requestId, p, verifier);
        _close(p, ClinovaTypes.ProofStatus.APPROVED, verifier);
        emit ProofApproved(requestId, p.provider, verifier, p.proofHash);
    }

    /// @notice SUBMITTED -> REJECTED by an independent verifier. Final: a rejected proof can never be approved.
    function reject(uint256 requestId, address verifier, bytes32 reasonHash) external onlyMarketplace {
        ClinovaTypes.ServiceProof storage p = _requireSubmitted(requestId);
        _requireIndependentVerifier(requestId, p, verifier);
        _close(p, ClinovaTypes.ProofStatus.REJECTED, verifier);
        emit ProofRejected(requestId, p.provider, verifier, p.proofHash, reasonHash);
    }

    /// @notice SUBMITTED -> BUYER_ACCEPTED when the request's own buyer confirms completion.
    function markBuyerAccepted(uint256 requestId, address buyer) external onlyMarketplace {
        ClinovaTypes.ServiceProof storage p = _requireSubmitted(requestId);
        address expected = _request(requestId).buyer;
        if (buyer != expected) revert BuyerMismatch(requestId, expected, buyer);
        _close(p, ClinovaTypes.ProofStatus.BUYER_ACCEPTED, buyer);
        emit ProofAcceptedByBuyer(requestId, p.provider, buyer, p.proofHash);
    }

    /// @notice SUBMITTED -> UNRESOLVED when the request closes by timeout before any review.
    function markUnresolved(uint256 requestId) external onlyMarketplace {
        ClinovaTypes.ServiceProof storage p = _requireSubmitted(requestId);
        _close(p, ClinovaTypes.ProofStatus.UNRESOLVED, address(0));
        emit ProofUnresolved(requestId, p.provider, p.proofHash);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The onchain binding of an evidence commitment to (chain, this contract, request, provider).
    function computeProofHash(uint256 requestId, address provider, bytes32 evidenceCommitment)
        public
        view
        returns (bytes32)
    {
        return
            keccak256(abi.encode(PROOF_DOMAIN, block.chainid, address(this), requestId, provider, evidenceCommitment));
    }

    function getProof(uint256 requestId) external view returns (ClinovaTypes.ServiceProof memory) {
        return _proofs[requestId];
    }

    function proofStatus(uint256 requestId) external view returns (ClinovaTypes.ProofStatus) {
        return _proofs[requestId].status;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _request(uint256 requestId) internal view returns (ClinovaTypes.ServiceRequest memory) {
        return IServiceMarketplace(marketplace).getRequest(requestId);
    }

    function _requireSubmitted(uint256 requestId) internal view returns (ClinovaTypes.ServiceProof storage p) {
        p = _proofs[requestId];
        if (p.status != ClinovaTypes.ProofStatus.SUBMITTED) revert ProofNotReviewable(requestId, p.status);
    }

    /// @dev The verifier must hold VERIFIER_ROLE on the marketplace and be neither the buyer nor the provider.
    function _requireIndependentVerifier(uint256 requestId, ClinovaTypes.ServiceProof storage p, address verifier)
        internal
        view
    {
        if (!IAccessControl(marketplace).hasRole(VERIFIER_ROLE, verifier)) revert NotVerifier(verifier);
        ClinovaTypes.ServiceRequest memory r = _request(requestId);
        if (verifier == r.buyer || verifier == r.provider || verifier == p.provider) {
            revert ConflictOfInterest(verifier);
        }
    }

    function _close(ClinovaTypes.ServiceProof storage p, ClinovaTypes.ProofStatus status, address reviewer) internal {
        p.status = status;
        p.reviewer = reviewer;
        p.reviewedAt = block.timestamp.toUint64();
    }
}
