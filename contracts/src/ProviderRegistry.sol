// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ClinovaTypes} from "./libraries/ClinovaTypes.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";

/// @title ProviderRegistry
/// @notice Registry of physical diagnostic providers: hashed profile, service capabilities, USDC stake,
///         verification and activation. Not a healthcare records system: only bytes32 commitments are stored.
/// @dev Lifecycle (docs/contract-spec.md §2):
///        register(+stake) -> verifyProvider (verifier) -> activate (provider) -> eligible
///      Stake custody is independent of service escrow (ClinovaEscrow). Stake leaves this contract only through
///      withdrawStake() to the provider's own address. No admin or marketplace function can move stake.
contract ProviderRegistry is IProviderRegistry, AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_MIN_STAKE = 100_000e6; // 100,000 USDC
    uint64 public constant MIN_UNBONDING_PERIOD = 1 days;
    uint64 public constant MAX_UNBONDING_PERIOD = 30 days;
    uint8 public constant USDC_DECIMALS = 6;

    bytes32 public constant MIN_STAKE_KEY = "MIN_STAKE";
    bytes32 public constant UNBONDING_PERIOD_KEY = "UNBONDING_PERIOD";

    IERC20 public immutable usdc;
    /// @notice The only address allowed to update active-job obligations. Fixed at deployment; not a role.
    address public immutable marketplace;

    uint256 public minStake;
    uint64 public unbondingPeriod;
    /// @notice Sum of all providers' recorded stake. Invariant: usdc.balanceOf(this) >= totalStaked.
    uint256 public totalStaked;

    mapping(address provider => ClinovaTypes.Provider) private _providers;
    mapping(address provider => mapping(bytes32 serviceType => bool)) private _offersService;
    mapping(uint256 requestId => ClinovaTypes.Job) private _jobs;

    modifier onlyMarketplace() {
        if (msg.sender != marketplace) revert OnlyMarketplace();
        _;
    }

    modifier onlyRegistered(address provider) {
        if (!_providers[provider].registered) revert ProviderNotFound(provider);
        _;
    }

    constructor(
        address admin,
        uint48 adminTransferDelay,
        IERC20 usdc_,
        address marketplace_,
        uint256 minStake_,
        uint64 unbondingPeriod_
    ) AccessControlDefaultAdminRules(adminTransferDelay, admin) {
        if (address(usdc_) == address(0) || marketplace_ == address(0)) revert ZeroAddress();
        if (IERC20Metadata(address(usdc_)).decimals() != USDC_DECIMALS) revert InvalidToken();
        usdc = usdc_;
        marketplace = marketplace_;
        _setMinStake(minStake_);
        _setUnbondingPeriod(unbondingPeriod_);
    }

    // ------------------------------------------------------------------
    // Provider (self)
    // ------------------------------------------------------------------

    /// @notice Register msg.sender as a provider with an initial stake of at least `minStake`.
    /// @dev Starts unverified and inactive. Requires prior USDC approval of `stakeAmount`.
    function register(bytes32 metadataHash, bytes32 locationHash, bytes32[] calldata capabilities, uint256 stakeAmount)
        external
        nonReentrant
        whenNotPaused
    {
        address provider = msg.sender;
        if (provider == marketplace) revert MarketplaceCannotBeProvider();
        ClinovaTypes.Provider storage p = _providers[provider];
        if (p.registered) revert ProviderAlreadyRegistered(provider);
        if (metadataHash == bytes32(0) || locationHash == bytes32(0)) revert InvalidHash();
        uint256 required = minStake;
        if (stakeAmount < required) revert InsufficientStake(stakeAmount, required);

        p.registered = true;
        p.metadataHash = metadataHash;
        p.locationHash = locationHash;
        emit ProviderRegistered(provider, metadataHash, locationHash);

        for (uint256 i = 0; i < capabilities.length; ++i) {
            _addCapability(provider, capabilities[i]);
        }

        _depositStake(p, stakeAmount);
    }

    /// @notice Update the profile commitments. Revokes verification (and therefore activation).
    function updateProfile(bytes32 metadataHash, bytes32 locationHash) external onlyRegistered(msg.sender) {
        if (metadataHash == bytes32(0) || locationHash == bytes32(0)) revert InvalidHash();
        ClinovaTypes.Provider storage p = _providers[msg.sender];
        p.metadataHash = metadataHash;
        p.locationHash = locationHash;
        emit ProviderProfileUpdated(msg.sender, metadataHash, locationHash);
        if (p.verified) _revokeVerification(msg.sender, p, msg.sender);
    }

    /// @notice Advertise a new capability. Revokes verification: new claims must be re-verified.
    function addCapability(bytes32 serviceType) external onlyRegistered(msg.sender) {
        _addCapability(msg.sender, serviceType);
        ClinovaTypes.Provider storage p = _providers[msg.sender];
        if (p.verified) _revokeVerification(msg.sender, p, msg.sender);
    }

    /// @notice Stop advertising a capability. Narrowing claims never requires re-verification.
    function removeCapability(bytes32 serviceType) external onlyRegistered(msg.sender) {
        if (!_offersService[msg.sender][serviceType]) revert CapabilityNotFound(serviceType);
        _offersService[msg.sender][serviceType] = false;
        emit ProviderCapabilityRemoved(msg.sender, serviceType);
    }

    /// @notice Top up stake. Blocked while paused or while an unstake is pending.
    function depositStake(uint256 amount) external nonReentrant whenNotPaused onlyRegistered(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        ClinovaTypes.Provider storage p = _providers[msg.sender];
        if (p.unstakeAvailableAt != 0) revert UnstakePending(p.unstakeAvailableAt);
        _depositStake(p, amount);
    }

    /// @notice Opt in to receiving new requests. Requires verification, sufficient stake and no pending unstake.
    function activate() external onlyRegistered(msg.sender) {
        ClinovaTypes.Provider storage p = _providers[msg.sender];
        if (p.active) revert ProviderAlreadyActive(msg.sender);
        if (!p.verified) revert ProviderNotVerified(msg.sender);
        if (p.unstakeAvailableAt != 0) revert UnstakePending(p.unstakeAvailableAt);
        uint256 required = minStake;
        if (p.stake < required) revert InsufficientStake(p.stake, required);
        p.active = true;
        emit ProviderActivated(msg.sender);
    }

    /// @notice Stop receiving new requests. Existing obligations (activeJobs) are unaffected.
    function deactivate() external onlyRegistered(msg.sender) {
        ClinovaTypes.Provider storage p = _providers[msg.sender];
        if (!p.active) revert ProviderInactive(msg.sender);
        _deactivate(msg.sender, p, DeactivationReason.SELF);
    }

    /// @notice Begin unbonding the full stake. Deactivates the provider; the unbonding period is snapshotted.
    function requestUnstake() external onlyRegistered(msg.sender) {
        ClinovaTypes.Provider storage p = _providers[msg.sender];
        if (p.unstakeAvailableAt != 0) revert UnstakePending(p.unstakeAvailableAt);
        if (p.stake == 0) revert NoStake();
        uint64 availableAt = block.timestamp.toUint64() + unbondingPeriod;
        p.unstakeAvailableAt = availableAt;
        if (p.active) _deactivate(msg.sender, p, DeactivationReason.UNSTAKE_REQUESTED);
        emit UnstakeRequested(msg.sender, p.stake, availableAt);
    }

    /// @notice Withdraw the full stake to msg.sender after unbonding, once no obligations remain.
    /// @dev Deliberately NOT pausable: pause must never lock provider funds.
    function withdrawStake() external nonReentrant {
        ClinovaTypes.Provider storage p = _providers[msg.sender];
        uint64 availableAt = p.unstakeAvailableAt;
        if (availableAt == 0) revert NoUnstakeRequested();
        // Day-scale unbonding: Arbitrum timestamp skew (hours) is immaterial here (docs/arbitrum-research.md).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < availableAt) revert UnstakeNotReady(availableAt);
        if (p.activeJobs != 0) revert ActiveObligation(p.activeJobs);

        uint256 amount = p.stake;
        p.stake = 0;
        p.unstakeAvailableAt = 0;
        totalStaked -= amount;
        emit ProviderStakeWithdrawn(msg.sender, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Verifier
    // ------------------------------------------------------------------

    function verifyProvider(address provider) external onlyRole(VERIFIER_ROLE) onlyRegistered(provider) {
        if (provider == msg.sender) revert SelfVerification();
        ClinovaTypes.Provider storage p = _providers[provider];
        if (p.verified) revert ProviderAlreadyVerified(provider);
        p.verified = true;
        emit ProviderVerified(provider, msg.sender);
    }

    /// @notice Revoke verification (e.g. licence lapsed). Also deactivates. Stake and in-flight jobs are untouched.
    function revokeVerification(address provider) external onlyRole(VERIFIER_ROLE) onlyRegistered(provider) {
        ClinovaTypes.Provider storage p = _providers[provider];
        if (!p.verified) revert ProviderNotVerified(provider);
        _revokeVerification(provider, p, msg.sender);
    }

    // ------------------------------------------------------------------
    // Marketplace (narrow obligation counter)
    // ------------------------------------------------------------------

    /// @notice Bind `requestId` to `provider` and count it as an open obligation.
    /// @dev The registry re-checks full eligibility itself, and a request id can be bound exactly once.
    function recordJobAccepted(uint256 requestId, address provider, bytes32 serviceType) external onlyMarketplace {
        ClinovaTypes.Job storage job = _jobs[requestId];
        if (job.status != ClinovaTypes.JobStatus.NONE) revert JobAlreadyRecorded(requestId);
        if (!isEligible(provider, serviceType)) revert ProviderNotEligible(provider, serviceType);
        job.provider = provider;
        job.status = ClinovaTypes.JobStatus.OPEN;
        ClinovaTypes.Provider storage p = _providers[provider];
        uint32 jobs = p.activeJobs + 1;
        p.activeJobs = jobs;
        emit JobOpened(requestId, provider, jobs);
    }

    /// @notice Close the obligation for `requestId`. `provider` must be the one bound at acceptance.
    function recordJobClosed(uint256 requestId, address provider) external onlyMarketplace {
        ClinovaTypes.Job storage job = _jobs[requestId];
        if (job.status != ClinovaTypes.JobStatus.OPEN) revert JobNotOpen(requestId);
        if (job.provider != provider) revert JobProviderMismatch(requestId, job.provider, provider);
        job.status = ClinovaTypes.JobStatus.CLOSED;
        ClinovaTypes.Provider storage p = _providers[provider];
        uint32 jobs = p.activeJobs - 1; // cannot underflow: an OPEN job was counted at acceptance
        p.activeJobs = jobs;
        emit JobClosed(requestId, provider, jobs);
    }

    // ------------------------------------------------------------------
    // Admin (bounded parameters) / pauser
    // ------------------------------------------------------------------

    /// @notice Affects eligibility for future acceptances only. Never touches existing stake.
    function setMinStake(uint256 newMinStake) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMinStake(newMinStake);
    }

    /// @notice Affects future unstake requests only; pending ones keep their snapshotted time.
    function setUnbondingPeriod(uint64 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setUnbondingPeriod(newPeriod);
    }

    /// @notice Blocks register() and depositStake() only. Exits are never pausable.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getProvider(address provider) external view returns (ClinovaTypes.Provider memory) {
        return _providers[provider];
    }

    function getJob(uint256 requestId) external view returns (ClinovaTypes.Job memory) {
        return _jobs[requestId];
    }

    function offersService(address provider, bytes32 serviceType) external view returns (bool) {
        return _offersService[provider][serviceType];
    }

    /// @notice registered && verified && active && no pending unstake && stake >= minStake && offers serviceType.
    function isEligible(address provider, bytes32 serviceType) public view returns (bool) {
        ClinovaTypes.Provider storage p = _providers[provider];
        return p.registered && p.verified && p.active && p.unstakeAvailableAt == 0 && p.stake >= minStake
            && _offersService[provider][serviceType];
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _addCapability(address provider, bytes32 serviceType) internal {
        if (serviceType == bytes32(0)) revert InvalidCapability();
        if (_offersService[provider][serviceType]) revert CapabilityAlreadyAdded(serviceType);
        _offersService[provider][serviceType] = true;
        emit ProviderCapabilityAdded(provider, serviceType);
    }

    /// @dev `p` must be msg.sender's record: stake is only ever pulled from the caller.
    ///      Effects first, then pull exactly `amount`; reverts if the received amount differs (e.g. fee-on-transfer).
    function _depositStake(ClinovaTypes.Provider storage p, uint256 amount) internal {
        uint128 newStake = (uint256(p.stake) + amount).toUint128();
        p.stake = newStake;
        totalStaked += amount;
        emit ProviderStakeDeposited(msg.sender, amount, newStake);

        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdc.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TransferAmountMismatch(amount, received);
    }

    function _revokeVerification(address provider, ClinovaTypes.Provider storage p, address by) internal {
        p.verified = false;
        emit ProviderVerificationRevoked(provider, by);
        if (p.active) _deactivate(provider, p, DeactivationReason.VERIFICATION_REVOKED);
    }

    function _deactivate(address provider, ClinovaTypes.Provider storage p, DeactivationReason reason) internal {
        p.active = false;
        emit ProviderDeactivated(provider, reason);
    }

    function _setMinStake(uint256 newMinStake) internal {
        if (newMinStake == 0 || newMinStake > MAX_MIN_STAKE) revert ParameterOutOfBounds(MIN_STAKE_KEY, newMinStake);
        emit ParameterUpdated(MIN_STAKE_KEY, minStake, newMinStake);
        minStake = newMinStake;
    }

    function _setUnbondingPeriod(uint64 newPeriod) internal {
        if (newPeriod < MIN_UNBONDING_PERIOD || newPeriod > MAX_UNBONDING_PERIOD) {
            revert ParameterOutOfBounds(UNBONDING_PERIOD_KEY, newPeriod);
        }
        emit ParameterUpdated(UNBONDING_PERIOD_KEY, unbondingPeriod, newPeriod);
        unbondingPeriod = newPeriod;
    }
}
