// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaTypes} from "../libraries/ClinovaTypes.sol";
import {IProviderRegistry} from "./IProviderRegistry.sol";
import {IClinovaEscrow} from "./IClinovaEscrow.sol";
import {IProofOfService} from "./IProofOfService.sol";
import {IReputationRegistry} from "./IReputationRegistry.sol";

/// @title IServiceMarketplace
/// @notice The only orchestrator of the request state machine (docs/contract-spec.md §1).
interface IServiceMarketplace {
    enum SettlementPath {
        BUYER_CONFIRMED,
        VERIFIER_APPROVED,
        DISPUTE_RESOLVED
    }

    event ServiceRequestCreated(
        uint256 indexed id,
        address indexed buyer,
        address indexed directedProvider,
        bytes32 serviceType,
        bytes32 locationHash,
        uint256 price,
        uint64 acceptDeadline,
        uint64 serviceDeadline
    );
    event ServiceRequestFunded(uint256 indexed id, address indexed buyer, uint256 amount);
    event ServiceRequestAccepted(uint256 indexed id, address indexed provider);
    event ServiceRequestStarted(uint256 indexed id, address indexed provider);
    event ServiceRequestCompleted(
        uint256 indexed id, address indexed provider, bytes32 proofHash, uint64 reviewDeadline
    );
    event DisputeEvidenceSubmitted(uint256 indexed id, address indexed provider, bytes32 proofHash);
    event ServiceRequestCancelled(uint256 indexed id, uint256 refundAmount);
    event ServiceRequestExpired(
        uint256 indexed id, address indexed by, ClinovaTypes.Status fromStatus, uint256 refundAmount
    );
    event ServiceRequestDisputed(
        uint256 indexed id,
        address indexed by,
        bytes32 reasonHash,
        ClinovaTypes.Status fromStatus,
        uint64 disputeDeadline
    );
    event CompletionClosedUnreviewed(uint256 indexed id, address indexed by);
    event DisputeResolved(uint256 indexed id, address indexed verifier, ClinovaTypes.Resolution resolution);
    event DisputeTimedOut(uint256 indexed id, address indexed by);
    event ServiceRequestSettled(uint256 indexed id, address indexed provider, uint256 amount, SettlementPath path);
    event ServiceRequestRefunded(uint256 indexed id, address indexed buyer, uint256 amount);
    event ParameterUpdated(bytes32 indexed key, uint256 oldValue, uint256 newValue);

    error ZeroAddress();
    error InvalidWiring();
    error InvalidStatus(uint256 id, ClinovaTypes.Status current);
    error NotBuyer(uint256 id);
    error NotAssignedProvider(uint256 id);
    error NotParty(uint256 id);
    error BuyerCannotAccept();
    error ConflictOfInterest(address verifier);
    error PriceTooLow(uint256 price, uint256 minPrice);
    error InvalidDeadlines();
    error DeadlinePassed(uint64 deadline);
    error DeadlineNotPassed(uint64 deadline);
    error InvalidServiceType();
    error InvalidHash();
    error ProofNotApprovable(uint256 id, ClinovaTypes.ProofStatus proofStatus);
    error TransferAmountMismatch(uint256 expected, uint256 received);
    error EscrowAmountMismatch(uint256 id, uint256 expected, uint256 moved);
    error ParameterOutOfBounds(bytes32 key, uint256 value);

    // --- buyer ---
    function createRequest(
        address directedProvider, // address(0) = open to any eligible provider
        bytes32 serviceType,
        bytes32 locationHash,
        uint128 price,
        uint64 acceptDeadline,
        uint64 serviceDeadline
    ) external returns (uint256 id);
    function cancelRequest(uint256 id) external;
    function confirmCompletion(uint256 id) external;

    // --- provider (always msg.sender) ---
    function acceptRequest(uint256 id) external;
    function startService(uint256 id) external;
    function submitProof(uint256 id, bytes32 evidenceCommitment) external;

    // --- parties ---
    function openDispute(uint256 id, bytes32 reasonHash) external;
    function expireRequest(uint256 id) external;

    // --- anyone, time-gated liveness exits ---
    function closeUnreviewed(uint256 id) external;
    function resolveDisputeByTimeout(uint256 id) external;

    // --- verifier ---
    function approveProof(uint256 id) external;
    function rejectProof(uint256 id, bytes32 reasonHash) external;
    function resolveDispute(uint256 id, ClinovaTypes.Resolution resolution) external;

    // --- admin (bounded) / pauser ---
    function setMinPrice(uint256 newMinPrice) external;
    function setReviewPeriod(uint32 newPeriod) external;
    function setDisputePeriod(uint32 newPeriod) external;
    function pause() external;
    function unpause() external;

    // --- views ---
    function registry() external view returns (IProviderRegistry);
    function escrow() external view returns (IClinovaEscrow);
    function getRequest(uint256 id) external view returns (ClinovaTypes.ServiceRequest memory);
    function proofOfService() external view returns (IProofOfService);
    function reputation() external view returns (IReputationRegistry);
    function nextRequestId() external view returns (uint256);
    function minPrice() external view returns (uint256);
    function reviewPeriod() external view returns (uint32);
    function disputePeriod() external view returns (uint32);
}
