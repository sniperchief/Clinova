// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaTypes} from "../libraries/ClinovaTypes.sol";
import {IProviderRegistry} from "./IProviderRegistry.sol";
import {IProofOfService} from "./IProofOfService.sol";

/// @title IReputationRegistry
/// @notice Objective per-provider outcome counters derived from finished requests. No scores, ratings,
///         tokens or NFTs, and no admin: history cannot be edited, reset or deleted.
/// @dev Exactly one record per accepted request, written by the immutable marketplace when the request reaches a
///      terminal state. The provider is never taken from the caller: it is read from the registry's job binding
///      and cross-checked against the marketplace request.
interface IReputationRegistry {
    enum Outcome {
        SUCCESS, // SETTLED to the provider
        PROVIDER_FAULT, // EXPIRED after acceptance, or REFUNDED with REFUND_PROVIDER_FAULT
        NO_FAULT // REFUNDED with REFUND_NO_FAULT, dispute timeout, or unreviewed completion closed
    }

    event OutcomeRecorded(
        uint256 indexed requestId, address indexed provider, Outcome outcome, bool proofSubmitted, bool disputed
    );
    event ReputationUpdated(
        address indexed provider, uint64 completedJobs, uint64 successfulJobs, uint64 failedJobs, uint64 disputes
    );

    error ZeroAddress();
    error OnlyMarketplace();
    error OutcomeAlreadyRecorded(uint256 requestId);
    error JobNotClosed(uint256 requestId);
    error ProviderMismatch(uint256 requestId, address jobProvider, address requestProvider);
    error InvalidOutcome(uint256 requestId, ClinovaTypes.Status status, bool providerAtFault);

    // --- marketplace only ---
    function recordOutcome(uint256 requestId, bool providerAtFault) external;

    // --- views ---
    function marketplace() external view returns (address);
    function registry() external view returns (IProviderRegistry);
    function proofOfService() external view returns (IProofOfService);
    function getReputation(address provider) external view returns (ClinovaTypes.Reputation memory);
    function outcomeRecorded(uint256 requestId) external view returns (bool);
}
