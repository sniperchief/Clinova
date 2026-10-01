// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ClinovaTypes
/// @notice Shared types for the Clinova protocol. See docs/contract-spec.md.
/// @dev PRIVACY: no field may hold patient data. Only ids, amounts, timestamps and salted bytes32 commitments.
library ClinovaTypes {
    /// @dev NONE = 0 marks a nonexistent request. Terminal: SETTLED, CANCELLED, EXPIRED, REFUNDED.
    enum Status {
        NONE,
        OPEN,
        ACCEPTED,
        IN_SERVICE,
        COMPLETED,
        SETTLED,
        CANCELLED,
        EXPIRED,
        DISPUTED,
        REFUNDED
    }

    /// @dev NONE -> SUBMITTED -> exactly one terminal state. There is no replacement and no status setter.
    ///      APPROVED: a non-party verifier accepted the evidence (or resolved a dispute for the provider).
    ///      REJECTED: a verifier did not accept the evidence. Final: can never lead to payment.
    ///      BUYER_ACCEPTED: the payer confirmed completion without verifier review.
    ///      UNRESOLVED: the request closed (timeout) before anyone reviewed the proof. Not a fault finding.
    enum ProofStatus {
        NONE,
        SUBMITTED,
        APPROVED,
        REJECTED,
        BUYER_ACCEPTED,
        UNRESOLVED
    }

    enum Resolution {
        PROVIDER_WINS,
        REFUND_PROVIDER_FAULT,
        REFUND_NO_FAULT
    }

    /// @dev Escrow's own per-request lifecycle, independent of the marketplace status.
    ///      NONE -> FUNDED -> (RELEASED | REFUNDED). Both outcomes are terminal.
    enum EscrowState {
        NONE,
        FUNDED,
        RELEASED,
        REFUNDED
    }

    /// @dev Registry-side record binding one request id to exactly one provider.
    enum JobStatus {
        NONE,
        OPEN,
        CLOSED
    }

    /// @dev Field order packs into 6 storage slots.
    struct ServiceRequest {
        address buyer;
        uint64 createdAt;
        Status status;
        Status disputedFrom; // NONE unless the request is (or was) disputed
        address provider; // directed provider, or address(0) for an open request until accepted
        uint64 acceptDeadline;
        bytes32 serviceType; // public catalog code, e.g. keccak256("LAB.CBC.V1")
        bytes32 locationHash; // coarse service region, never a patient address
        uint128 price; // USDC base units (6 decimals); equals the escrowed amount; immutable after creation
        uint64 serviceDeadline;
        uint32 reviewPeriod; // snapshotted at creation
        uint32 disputePeriod; // snapshotted at creation
        uint64 reviewDeadline; // set on COMPLETED
        uint64 disputeDeadline; // set on DISPUTED
    }

    struct Deposit {
        address payer;
        uint128 amount;
        EscrowState state;
        address payee; // bound once, at acceptance
    }

    struct Provider {
        bytes32 metadataHash; // commitment to offchain business profile
        bytes32 locationHash; // coarse service region
        uint128 stake; // USDC base units
        uint64 unstakeAvailableAt; // 0 unless an unstake is pending
        uint32 activeJobs;
        bool registered;
        bool verified;
        bool active;
    }

    struct Job {
        address provider;
        JobStatus status;
    }

    struct ServiceProof {
        address provider; // the provider bound to the request at acceptance
        uint64 submittedAt;
        ProofStatus status;
        address reviewer; // verifier or buyer who closed it; address(0) for UNRESOLVED
        uint64 reviewedAt;
        bytes32 evidenceCommitment; // provider-supplied salted commitment to the encrypted evidence bundle
        bytes32 proofHash; // computed onchain: binds commitment to chain, contract, request and provider
    }

    /// @dev Objective per-provider outcome counters (one slot). Each request contributes at most once.
    struct Reputation {
        uint64 completedJobs; // requests where the provider submitted a completion proof
        uint64 successfulJobs; // requests that settled to the provider
        uint64 failedJobs; // requests that ended with the provider at fault
        uint64 disputes; // requests that were disputed (by a party) or had their proof rejected
    }

    function isTerminal(Status s) internal pure returns (bool) {
        return s == Status.SETTLED || s == Status.CANCELLED || s == Status.EXPIRED || s == Status.REFUNDED;
    }
}
