// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClinovaTypes} from "../libraries/ClinovaTypes.sol";

/// @title IProviderRegistry
/// @notice Provider records, service capabilities, USDC stake custody and verification status.
/// @dev Stake leaves the registry only via withdrawStake() to the provider itself. No slashing in the MVP.
///      Eligibility = registered && verified && active && no pending unstake && stake >= minStake && offers service.
interface IProviderRegistry {
    enum DeactivationReason {
        SELF,
        UNSTAKE_REQUESTED,
        VERIFICATION_REVOKED
    }

    event ProviderRegistered(address indexed provider, bytes32 metadataHash, bytes32 locationHash);
    event ProviderProfileUpdated(address indexed provider, bytes32 metadataHash, bytes32 locationHash);
    event ProviderCapabilityAdded(address indexed provider, bytes32 indexed serviceType);
    event ProviderCapabilityRemoved(address indexed provider, bytes32 indexed serviceType);
    event ProviderStakeDeposited(address indexed provider, uint256 amount, uint256 totalStake);
    event ProviderVerified(address indexed provider, address indexed verifier);
    event ProviderVerificationRevoked(address indexed provider, address indexed by);
    event ProviderActivated(address indexed provider);
    event ProviderDeactivated(address indexed provider, DeactivationReason reason);
    event UnstakeRequested(address indexed provider, uint256 amount, uint64 availableAt);
    event ProviderStakeWithdrawn(address indexed provider, uint256 amount);
    event JobOpened(uint256 indexed requestId, address indexed provider, uint32 activeJobs);
    event JobClosed(uint256 indexed requestId, address indexed provider, uint32 activeJobs);
    event ParameterUpdated(bytes32 indexed key, uint256 oldValue, uint256 newValue);

    error ZeroAddress();
    error InvalidToken();
    error InvalidHash();
    error InvalidCapability();
    error ProviderAlreadyRegistered(address provider);
    error ProviderNotFound(address provider);
    error ProviderAlreadyVerified(address provider);
    error ProviderNotVerified(address provider);
    error ProviderAlreadyActive(address provider);
    error ProviderInactive(address provider);
    error ProviderNotEligible(address provider, bytes32 serviceType);
    error CapabilityAlreadyAdded(bytes32 serviceType);
    error CapabilityNotFound(bytes32 serviceType);
    error InsufficientStake(uint256 stake, uint256 required);
    error ZeroAmount();
    error NoStake();
    error TransferAmountMismatch(uint256 expected, uint256 received);
    error UnstakePending(uint64 availableAt);
    error NoUnstakeRequested();
    error UnstakeNotReady(uint64 availableAt);
    error ActiveObligation(uint32 activeJobs);
    error JobAlreadyRecorded(uint256 requestId);
    error JobNotOpen(uint256 requestId);
    error JobProviderMismatch(uint256 requestId, address expected, address actual);
    error SelfVerification();
    error OnlyMarketplace();
    error MarketplaceCannotBeProvider();
    error ParameterOutOfBounds(bytes32 key, uint256 value);

    // --- provider (self; msg.sender is always the provider) ---
    function register(bytes32 metadataHash, bytes32 locationHash, bytes32[] calldata capabilities, uint256 stakeAmount)
        external;
    function updateProfile(bytes32 metadataHash, bytes32 locationHash) external; // revokes verification
    function addCapability(bytes32 serviceType) external; // revokes verification
    function removeCapability(bytes32 serviceType) external;
    function depositStake(uint256 amount) external;
    function activate() external;
    function deactivate() external;
    function requestUnstake() external;
    function withdrawStake() external;

    // --- verifier ---
    function verifyProvider(address provider) external;
    function revokeVerification(address provider) external;

    // --- marketplace only (per-request obligation binding; no access to stake or provider fields) ---
    function recordJobAccepted(uint256 requestId, address provider, bytes32 serviceType) external;
    function recordJobClosed(uint256 requestId, address provider) external;

    // --- admin (bounded) / pauser ---
    function setMinStake(uint256 newMinStake) external;
    function setUnbondingPeriod(uint64 newPeriod) external;
    function pause() external;
    function unpause() external;

    // --- views ---
    function getProvider(address provider) external view returns (ClinovaTypes.Provider memory);
    function offersService(address provider, bytes32 serviceType) external view returns (bool);
    function isEligible(address provider, bytes32 serviceType) external view returns (bool);
    function minStake() external view returns (uint256);
    function unbondingPeriod() external view returns (uint64);
    function totalStaked() external view returns (uint256);
    function getJob(uint256 requestId) external view returns (ClinovaTypes.Job memory);
    function marketplace() external view returns (address);
    function usdc() external view returns (IERC20);
}
