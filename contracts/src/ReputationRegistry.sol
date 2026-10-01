// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaTypes} from "./libraries/ClinovaTypes.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {IServiceMarketplace} from "./interfaces/IServiceMarketplace.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IProofOfService} from "./interfaces/IProofOfService.sol";

/// @title ReputationRegistry
/// @notice Objective, append-only provider outcome counters. One record per accepted request, at its end.
/// @dev Counting rules (docs/contract-spec.md §8):
///        completedJobs  += 1 if the provider submitted a completion proof for the request
///        successfulJobs += 1 if the request SETTLED to the provider
///        failedJobs     += 1 if the provider was at fault (EXPIRED after acceptance, or REFUND_PROVIDER_FAULT)
///        disputes       += 1 if the request was disputed by a party or its proof was rejected
///      Everything except the fault flag of a verifier refund is derived here from the registry job binding,
///      the marketplace request and the proof record. There is no admin and no function that edits counters.
contract ReputationRegistry is IReputationRegistry {
    address public immutable marketplace;
    IProviderRegistry public immutable registry;
    IProofOfService public immutable proofOfService;

    mapping(address provider => ClinovaTypes.Reputation) private _reputation;
    mapping(uint256 requestId => bool) public outcomeRecorded;

    modifier onlyMarketplace() {
        if (msg.sender != marketplace) revert OnlyMarketplace();
        _;
    }

    constructor(address marketplace_, IProviderRegistry registry_, IProofOfService proofOfService_) {
        if (marketplace_ == address(0) || address(registry_) == address(0) || address(proofOfService_) == address(0)) {
            revert ZeroAddress();
        }
        marketplace = marketplace_;
        registry = registry_;
        proofOfService = proofOfService_;
    }

    /// @notice Record the final outcome of `requestId` for the provider that accepted it. Callable once.
    /// @param providerAtFault only meaningful for REFUNDED (the verifier's decision); validated otherwise.
    function recordOutcome(uint256 requestId, bool providerAtFault) external onlyMarketplace {
        if (outcomeRecorded[requestId]) revert OutcomeAlreadyRecorded(requestId);

        // The accepting provider comes from the registry's one-time job binding, never from the caller.
        ClinovaTypes.Job memory job = registry.getJob(requestId);
        if (job.status != ClinovaTypes.JobStatus.CLOSED) revert JobNotClosed(requestId);
        ClinovaTypes.ServiceRequest memory r = IServiceMarketplace(marketplace).getRequest(requestId);
        if (r.provider != job.provider) revert ProviderMismatch(requestId, job.provider, r.provider);

        Outcome outcome = _classify(requestId, r.status, providerAtFault);
        bool proofSubmitted = proofOfService.proofStatus(requestId) != ClinovaTypes.ProofStatus.NONE;
        bool disputed = r.disputedFrom != ClinovaTypes.Status.NONE;

        outcomeRecorded[requestId] = true;
        ClinovaTypes.Reputation storage rep = _reputation[job.provider];
        if (proofSubmitted) rep.completedJobs++;
        if (outcome == Outcome.SUCCESS) rep.successfulJobs++;
        if (outcome == Outcome.PROVIDER_FAULT) rep.failedJobs++;
        if (disputed) rep.disputes++;

        emit OutcomeRecorded(requestId, job.provider, outcome, proofSubmitted, disputed);
        emit ReputationUpdated(job.provider, rep.completedJobs, rep.successfulJobs, rep.failedJobs, rep.disputes);
    }

    function getReputation(address provider) external view returns (ClinovaTypes.Reputation memory) {
        return _reputation[provider];
    }

    /// @dev SETTLED is never a fault; EXPIRED after acceptance always is; REFUNDED carries the verifier's decision.
    function _classify(uint256 requestId, ClinovaTypes.Status status, bool providerAtFault)
        internal
        pure
        returns (Outcome)
    {
        if (status == ClinovaTypes.Status.SETTLED && !providerAtFault) return Outcome.SUCCESS;
        if (status == ClinovaTypes.Status.EXPIRED && providerAtFault) return Outcome.PROVIDER_FAULT;
        if (status == ClinovaTypes.Status.REFUNDED) return providerAtFault ? Outcome.PROVIDER_FAULT : Outcome.NO_FAULT;
        revert InvalidOutcome(requestId, status, providerAtFault);
    }
}
