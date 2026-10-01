// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaTypes} from "../libraries/ClinovaTypes.sol";

/// @title IProofOfService
/// @notice Source of truth for completion-proof commitments and their review lifecycle.
///         A proof is a cryptographic commitment to offchain evidence. It is NOT medical verification:
///         whether evidence supports completion is decided by an authorized verifier (or the paying buyer).
/// @dev Lifecycle: NONE -> SUBMITTED -> (APPROVED | REJECTED | BUYER_ACCEPTED | UNRESOLVED), all terminal.
///      Writes are restricted to the immutable marketplace address, and every write independently re-checks
///      the request/provider/verifier relationships against the marketplace's own state.
interface IProofOfService {
    event ProofSubmitted(
        uint256 indexed requestId,
        address indexed provider,
        bytes32 indexed proofHash,
        bytes32 evidenceCommitment,
        uint64 submittedAt
    );
    event ProofApproved(
        uint256 indexed requestId, address indexed provider, address indexed verifier, bytes32 proofHash
    );
    event ProofRejected(
        uint256 indexed requestId,
        address indexed provider,
        address indexed verifier,
        bytes32 proofHash,
        bytes32 reasonHash
    );
    event ProofAcceptedByBuyer(
        uint256 indexed requestId, address indexed provider, address indexed buyer, bytes32 proofHash
    );
    event ProofUnresolved(uint256 indexed requestId, address indexed provider, bytes32 proofHash);

    error ZeroAddress();
    error OnlyMarketplace();
    error InvalidCommitment();
    error ProofAlreadySubmitted(uint256 requestId);
    error EvidenceAlreadyUsed(address provider, bytes32 evidenceCommitment);
    error ProviderMismatch(uint256 requestId, address expected, address actual);
    error BuyerMismatch(uint256 requestId, address expected, address actual);
    error NotVerifier(address account);
    error ConflictOfInterest(address verifier);
    error ProofNotReviewable(uint256 requestId, ClinovaTypes.ProofStatus current);

    // --- marketplace only ---
    function submit(uint256 requestId, address provider, bytes32 evidenceCommitment)
        external
        returns (bytes32 proofHash);
    function approve(uint256 requestId, address verifier) external;
    function reject(uint256 requestId, address verifier, bytes32 reasonHash) external;
    function markBuyerAccepted(uint256 requestId, address buyer) external;
    function markUnresolved(uint256 requestId) external;

    // --- views ---
    function marketplace() external view returns (address);
    function computeProofHash(uint256 requestId, address provider, bytes32 evidenceCommitment)
        external
        view
        returns (bytes32);
    function getProof(uint256 requestId) external view returns (ClinovaTypes.ServiceProof memory);
    function proofStatus(uint256 requestId) external view returns (ClinovaTypes.ProofStatus);
    function evidenceUsed(address provider, bytes32 evidenceCommitment) external view returns (bool);
}
