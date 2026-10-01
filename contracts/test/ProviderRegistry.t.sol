// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ProviderRegistryBase} from "./ProviderRegistryBase.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {
    MockUSDC,
    Mock18Decimals,
    FeeOnTransferToken,
    FalseReturnToken,
    HookToken,
    ITokenReceiverHook
} from "./mocks/Mocks.sol";

/// @notice A provider implemented as a contract that re-enters the registry from a token hook.
contract ReentrantProvider is ITokenReceiverHook {
    enum Attack {
        NONE,
        WITHDRAW,
        DEPOSIT
    }

    ProviderRegistry public immutable registry;
    Attack public attack;

    constructor(ProviderRegistry registry_, IERC20 token) {
        registry = registry_;
        token.approve(address(registry_), type(uint256).max);
    }

    function setAttack(Attack a) external {
        attack = a;
    }

    function register(bytes32[] calldata caps, uint256 stake) external {
        registry.register(keccak256("m"), keccak256("l"), caps, stake);
    }

    function depositStake(uint256 amount) external {
        registry.depositStake(amount);
    }

    function requestUnstake() external {
        registry.requestUnstake();
    }

    function withdrawStake() external {
        registry.withdrawStake();
    }

    function onTokenTransfer() external {
        Attack a = attack;
        attack = Attack.NONE; // single re-entry attempt
        if (a == Attack.WITHDRAW) registry.withdrawStake();
        else if (a == Attack.DEPOSIT) registry.depositStake(1e6);
    }
}

contract ProviderRegistryTest is ProviderRegistryBase {
    // ------------------------------------------------------------------
    // Constructor / configuration
    // ------------------------------------------------------------------

    function test_Constructor_SetsState() public view {
        assertEq(address(registry.usdc()), address(usdc));
        assertEq(registry.marketplace(), marketplace);
        assertEq(registry.minStake(), MIN_STAKE);
        assertEq(registry.unbondingPeriod(), UNBONDING);
        assertEq(registry.defaultAdmin(), admin);
        assertEq(registry.defaultAdminDelay(), ADMIN_DELAY);
        assertTrue(registry.hasRole(registry.VERIFIER_ROLE(), verifier));
        assertTrue(registry.hasRole(registry.PAUSER_ROLE(), pauser));
        assertEq(registry.totalStaked(), 0);
    }

    function test_Constructor_RevertsOnZeroToken() public {
        vm.expectRevert(IProviderRegistry.ZeroAddress.selector);
        new ProviderRegistry(admin, ADMIN_DELAY, IERC20(address(0)), marketplace, MIN_STAKE, UNBONDING);
    }

    function test_Constructor_RevertsOnZeroMarketplace() public {
        vm.expectRevert(IProviderRegistry.ZeroAddress.selector);
        new ProviderRegistry(admin, ADMIN_DELAY, IERC20(address(usdc)), address(0), MIN_STAKE, UNBONDING);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new ProviderRegistry(address(0), ADMIN_DELAY, IERC20(address(usdc)), marketplace, MIN_STAKE, UNBONDING);
    }

    function test_Constructor_RevertsOnWrongDecimals() public {
        Mock18Decimals bad = new Mock18Decimals();
        vm.expectRevert(IProviderRegistry.InvalidToken.selector);
        new ProviderRegistry(admin, ADMIN_DELAY, IERC20(address(bad)), marketplace, MIN_STAKE, UNBONDING);
    }

    function test_Constructor_RevertsOnParamsOutOfBounds() public {
        bytes32 minKey = registry.MIN_STAKE_KEY();
        bytes32 unbondKey = registry.UNBONDING_PERIOD_KEY();
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ParameterOutOfBounds.selector, minKey, 0));
        new ProviderRegistry(admin, ADMIN_DELAY, IERC20(address(usdc)), marketplace, 0, UNBONDING);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ParameterOutOfBounds.selector, unbondKey, 1 hours));
        new ProviderRegistry(admin, ADMIN_DELAY, IERC20(address(usdc)), marketplace, MIN_STAKE, 1 hours);
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    function test_Register_Valid() public {
        _fund(alice, MIN_STAKE);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderRegistered(alice, META, LOC);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IProviderRegistry.ProviderCapabilityAdded(alice, CBC);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IProviderRegistry.ProviderCapabilityAdded(alice, MALARIA);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderStakeDeposited(alice, MIN_STAKE, MIN_STAKE);

        vm.prank(alice);
        registry.register(META, LOC, _caps(), MIN_STAKE);

        assertEq(usdc.balanceOf(address(registry)), MIN_STAKE);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(registry.totalStaked(), MIN_STAKE);
        assertTrue(registry.offersService(alice, CBC));
        assertTrue(registry.offersService(alice, MALARIA));
        assertFalse(registry.offersService(alice, GLUCOSE));
    }

    function test_Register_InitialState() public {
        _register(alice, MIN_STAKE);
        ClinovaTypes.Provider memory p = _provider(alice);
        assertTrue(p.registered);
        assertFalse(p.verified);
        assertFalse(p.active);
        assertEq(p.metadataHash, META);
        assertEq(p.locationHash, LOC);
        assertEq(p.stake, MIN_STAKE);
        assertEq(p.unstakeAvailableAt, 0);
        assertEq(p.activeJobs, 0);
        assertFalse(registry.isEligible(alice, CBC), "registration must not bypass verification");
    }

    function test_Register_AboveMinimumStake() public {
        _register(alice, MIN_STAKE * 3);
        assertEq(_provider(alice).stake, MIN_STAKE * 3);
        assertEq(registry.totalStaked(), MIN_STAKE * 3);
    }

    function test_Register_WithNoCapabilities() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        registry.register(META, LOC, new bytes32[](0), MIN_STAKE);
        assertTrue(_provider(alice).registered);
        assertFalse(registry.offersService(alice, CBC));
    }

    function test_Register_RevertsDuplicate() public {
        _register(alice, MIN_STAKE);
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderAlreadyRegistered.selector, alice));
        registry.register(META, LOC, _caps(), MIN_STAKE);
    }

    function test_Register_RevertsInsufficientStake() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.InsufficientStake.selector, MIN_STAKE - 1, MIN_STAKE));
        registry.register(META, LOC, _caps(), MIN_STAKE - 1);
    }

    function test_Register_RevertsZeroStake() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.InsufficientStake.selector, 0, MIN_STAKE));
        registry.register(META, LOC, _caps(), 0);
    }

    function test_Register_RevertsZeroMetadataHash() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(IProviderRegistry.InvalidHash.selector);
        registry.register(bytes32(0), LOC, _caps(), MIN_STAKE);
    }

    function test_Register_RevertsZeroLocationHash() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(IProviderRegistry.InvalidHash.selector);
        registry.register(META, bytes32(0), _caps(), MIN_STAKE);
    }

    function test_Register_RevertsZeroCapability() public {
        _fund(alice, MIN_STAKE);
        bytes32[] memory caps = new bytes32[](1);
        vm.prank(alice);
        vm.expectRevert(IProviderRegistry.InvalidCapability.selector);
        registry.register(META, LOC, caps, MIN_STAKE);
    }

    function test_Register_RevertsDuplicateCapabilityInArray() public {
        _fund(alice, MIN_STAKE);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CBC;
        caps[1] = CBC;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.CapabilityAlreadyAdded.selector, CBC));
        registry.register(META, LOC, caps, MIN_STAKE);
    }

    function test_Register_RevertsWithoutAllowance() public {
        usdc.mint(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), 0, MIN_STAKE)
        );
        registry.register(META, LOC, _caps(), MIN_STAKE);
    }

    function test_Register_RevertsInsufficientBalance() public {
        _fund(alice, MIN_STAKE - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, MIN_STAKE - 1, MIN_STAKE)
        );
        registry.register(META, LOC, _caps(), MIN_STAKE);
        assertFalse(_provider(alice).registered, "failed transfer must not leave a registration");
    }

    function test_Register_RevertsForMarketplace() public {
        _fund(marketplace, MIN_STAKE);
        vm.prank(marketplace);
        vm.expectRevert(IProviderRegistry.MarketplaceCannotBeProvider.selector);
        registry.register(META, LOC, _caps(), MIN_STAKE);
    }

    function test_Register_RevertsWhenPaused() public {
        vm.prank(pauser);
        registry.pause();
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.register(META, LOC, _caps(), MIN_STAKE);
    }

    function test_ZeroAddress_IsNeverAProvider() public {
        assertFalse(_provider(address(0)).registered);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, address(0)));
        registry.verifyProvider(address(0));
    }

    // ------------------------------------------------------------------
    // Profile
    // ------------------------------------------------------------------

    function test_UpdateProfile_RevokesVerificationAndDeactivates() public {
        _eligible(alice, MIN_STAKE);
        bytes32 newMeta = keccak256("meta2");
        bytes32 newLoc = keccak256("loc2");

        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderProfileUpdated(alice, newMeta, newLoc);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IProviderRegistry.ProviderVerificationRevoked(alice, alice);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderDeactivated(alice, IProviderRegistry.DeactivationReason.VERIFICATION_REVOKED);

        vm.prank(alice);
        registry.updateProfile(newMeta, newLoc);

        ClinovaTypes.Provider memory p = _provider(alice);
        assertEq(p.metadataHash, newMeta);
        assertEq(p.locationHash, newLoc);
        assertFalse(p.verified);
        assertFalse(p.active);
        assertEq(p.stake, MIN_STAKE, "stake untouched");
    }

    function test_UpdateProfile_RevertsInvalidHash() public {
        _register(alice, MIN_STAKE);
        vm.startPrank(alice);
        vm.expectRevert(IProviderRegistry.InvalidHash.selector);
        registry.updateProfile(bytes32(0), LOC);
        vm.expectRevert(IProviderRegistry.InvalidHash.selector);
        registry.updateProfile(META, bytes32(0));
        vm.stopPrank();
    }

    function test_UpdateProfile_RevertsUnregistered() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, attacker));
        registry.updateProfile(META, LOC);
    }

    // ------------------------------------------------------------------
    // Verification
    // ------------------------------------------------------------------

    function test_Verify_ByVerifier() public {
        _register(alice, MIN_STAKE);
        ClinovaTypes.Provider memory before = _provider(alice);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IProviderRegistry.ProviderVerified(alice, verifier);
        vm.prank(verifier);
        registry.verifyProvider(alice);

        ClinovaTypes.Provider memory afterV = _provider(alice);
        assertTrue(afterV.verified);
        // No unrelated field is modified.
        assertEq(afterV.metadataHash, before.metadataHash);
        assertEq(afterV.locationHash, before.locationHash);
        assertEq(afterV.stake, before.stake);
        assertEq(afterV.active, before.active);
        assertEq(afterV.activeJobs, before.activeJobs);
        assertEq(afterV.unstakeAvailableAt, before.unstakeAvailableAt);
    }

    function test_Verify_RevertsUnauthorized() public {
        _register(alice, MIN_STAKE);
        bytes32 role = registry.VERIFIER_ROLE();
        address[4] memory callers = [attacker, alice, admin, marketplace];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], role)
            );
            registry.verifyProvider(alice);
        }
        assertFalse(_provider(alice).verified);
    }

    function test_Verify_RevertsNonexistentProvider() public {
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, bob));
        registry.verifyProvider(bob);
    }

    function test_Verify_RevertsRepeated() public {
        _registerVerified(alice, MIN_STAKE);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderAlreadyVerified.selector, alice));
        registry.verifyProvider(alice);
    }

    function test_Verify_RevertsSelfVerification() public {
        _register(verifier, MIN_STAKE);
        vm.prank(verifier);
        vm.expectRevert(IProviderRegistry.SelfVerification.selector);
        registry.verifyProvider(verifier);
    }

    function test_Revoke_DeactivatesButKeepsStakeAndJobs() public {
        _eligible(alice, MIN_STAKE);
        vm.prank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IProviderRegistry.ProviderVerificationRevoked(alice, verifier);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderDeactivated(alice, IProviderRegistry.DeactivationReason.VERIFICATION_REVOKED);
        vm.prank(verifier);
        registry.revokeVerification(alice);

        ClinovaTypes.Provider memory p = _provider(alice);
        assertFalse(p.verified);
        assertFalse(p.active);
        assertEq(p.stake, MIN_STAKE);
        assertEq(p.activeJobs, 1, "in-flight obligations survive revocation");
        assertFalse(registry.isEligible(alice, CBC));

        // The in-flight job can still be closed.
        vm.prank(marketplace);
        registry.recordJobClosed(REQ, alice);
        assertEq(_provider(alice).activeJobs, 0);
    }

    function test_Revoke_InactiveProviderOnlyClearsVerified() public {
        _registerVerified(alice, MIN_STAKE);
        vm.recordLogs();
        vm.prank(verifier);
        registry.revokeVerification(alice);
        assertEq(vm.getRecordedLogs().length, 1, "no deactivation event for an inactive provider");
        assertFalse(_provider(alice).verified);
    }

    function test_Revoke_RevertsWhenNotVerified() public {
        _register(alice, MIN_STAKE);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotVerified.selector, alice));
        registry.revokeVerification(alice);
    }

    function test_Revoke_RevertsUnauthorized() public {
        _registerVerified(alice, MIN_STAKE);
        bytes32 role = registry.VERIFIER_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        registry.revokeVerification(alice);
    }

    function test_Revoke_RevertsNonexistent() public {
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, bob));
        registry.revokeVerification(bob);
    }

    function test_Reverify_AfterRevocation() public {
        _registerVerified(alice, MIN_STAKE);
        vm.startPrank(verifier);
        registry.revokeVerification(alice);
        registry.verifyProvider(alice);
        vm.stopPrank();
        assertTrue(_provider(alice).verified);
    }

    // ------------------------------------------------------------------
    // Capabilities
    // ------------------------------------------------------------------

    function test_AddCapability() public {
        _register(alice, MIN_STAKE);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IProviderRegistry.ProviderCapabilityAdded(alice, GLUCOSE);
        vm.prank(alice);
        registry.addCapability(GLUCOSE);
        assertTrue(registry.offersService(alice, GLUCOSE));
    }

    function test_AddCapability_RevokesVerification() public {
        _eligible(alice, MIN_STAKE);
        vm.prank(alice);
        registry.addCapability(LIPID);
        ClinovaTypes.Provider memory p = _provider(alice);
        assertFalse(p.verified, "new capability claims need re-verification");
        assertFalse(p.active);
        assertFalse(registry.isEligible(alice, LIPID));
        assertFalse(registry.isEligible(alice, CBC));
    }

    function test_AddCapability_RevertsDuplicate() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.CapabilityAlreadyAdded.selector, CBC));
        registry.addCapability(CBC);
    }

    function test_AddCapability_RevertsZero() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(IProviderRegistry.InvalidCapability.selector);
        registry.addCapability(bytes32(0));
    }

    function test_AddCapability_RevertsUnregistered() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, attacker));
        registry.addCapability(CBC);
    }

    function test_RemoveCapability_KeepsVerification() public {
        _eligible(alice, MIN_STAKE);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IProviderRegistry.ProviderCapabilityRemoved(alice, MALARIA);
        vm.prank(alice);
        registry.removeCapability(MALARIA);
        assertFalse(registry.offersService(alice, MALARIA));
        assertFalse(registry.isEligible(alice, MALARIA));
        assertTrue(registry.isEligible(alice, CBC), "narrowing claims keeps verification");
    }

    function test_RemoveCapability_RevertsNonexistent() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.CapabilityNotFound.selector, GLUCOSE));
        registry.removeCapability(GLUCOSE);
    }

    function test_RemoveCapability_RevertsUnregistered() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, attacker));
        registry.removeCapability(CBC);
    }

    function test_Capabilities_CannotModifyAnotherProvider() public {
        _register(alice, MIN_STAKE);
        _register(bob, MIN_STAKE);
        // Bob's calls always act on Bob's own record; there is no provider parameter to target Alice.
        vm.prank(bob);
        registry.removeCapability(CBC);
        assertTrue(registry.offersService(alice, CBC));
        assertFalse(registry.offersService(bob, CBC));
    }

    // ------------------------------------------------------------------
    // Activation / deactivation / eligibility
    // ------------------------------------------------------------------

    function test_Activate_Valid() public {
        _registerVerified(alice, MIN_STAKE);
        vm.expectEmit(true, false, false, false, address(registry));
        emit IProviderRegistry.ProviderActivated(alice);
        vm.prank(alice);
        registry.activate();
        assertTrue(_provider(alice).active);
        assertTrue(registry.isEligible(alice, CBC));
        assertTrue(registry.isEligible(alice, MALARIA));
        assertFalse(registry.isEligible(alice, GLUCOSE), "not eligible for unoffered service");
    }

    function test_Activate_RevertsBeforeVerification() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotVerified.selector, alice));
        registry.activate();
    }

    function test_Activate_RevertsUnregistered() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, attacker));
        registry.activate();
    }

    function test_Activate_RevertsAlreadyActive() public {
        _eligible(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderAlreadyActive.selector, alice));
        registry.activate();
    }

    function test_Activate_RevertsWithPendingUnstake() public {
        _registerVerified(alice, MIN_STAKE);
        vm.startPrank(alice);
        registry.requestUnstake();
        uint64 at = _provider(alice).unstakeAvailableAt;
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.UnstakePending.selector, at));
        registry.activate();
        vm.stopPrank();
    }

    function test_Activate_RevertsWhenStakeBelowRaisedMinimum() public {
        _registerVerified(alice, MIN_STAKE);
        vm.prank(admin);
        registry.setMinStake(MIN_STAKE * 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.InsufficientStake.selector, MIN_STAKE, MIN_STAKE * 2));
        registry.activate();
    }

    function test_Deactivate_Self() public {
        _eligible(alice, MIN_STAKE);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderDeactivated(alice, IProviderRegistry.DeactivationReason.SELF);
        vm.prank(alice);
        registry.deactivate();
        assertFalse(_provider(alice).active);
        assertTrue(_provider(alice).verified, "self-deactivation keeps verification");
        assertFalse(registry.isEligible(alice, CBC));
    }

    function test_Deactivate_RevertsWhenInactive() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderInactive.selector, alice));
        registry.deactivate();
    }

    function test_Deactivate_ThenSelfReactivate() public {
        _eligible(alice, MIN_STAKE);
        vm.startPrank(alice);
        registry.deactivate();
        registry.activate();
        vm.stopPrank();
        assertTrue(registry.isEligible(alice, CBC));
    }

    function test_Reactivation_BlockedAfterRevocation() public {
        _eligible(alice, MIN_STAKE);
        vm.prank(verifier);
        registry.revokeVerification(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotVerified.selector, alice));
        registry.activate();
    }

    function test_Deactivate_DoesNotAffectObligations() public {
        _eligible(alice, MIN_STAKE);
        vm.prank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);
        vm.prank(alice);
        registry.deactivate();
        assertEq(_provider(alice).activeJobs, 1);
        vm.prank(marketplace);
        registry.recordJobClosed(REQ, alice);
        assertEq(_provider(alice).activeJobs, 0);
    }

    function test_Eligibility_LostWhenMinStakeRaised_StakeUntouched() public {
        _eligible(alice, MIN_STAKE);
        vm.prank(admin);
        registry.setMinStake(MIN_STAKE + 1);
        assertFalse(registry.isEligible(alice, CBC));
        assertEq(_provider(alice).stake, MIN_STAKE);
        // Topping up restores eligibility without re-activation.
        _fund(alice, 1);
        vm.prank(alice);
        registry.depositStake(1);
        assertTrue(registry.isEligible(alice, CBC));
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------

    function test_DepositStake_Additional() public {
        _register(alice, MIN_STAKE);
        _fund(alice, 250e6);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderStakeDeposited(alice, 250e6, MIN_STAKE + 250e6);
        vm.prank(alice);
        registry.depositStake(250e6);
        assertEq(_provider(alice).stake, MIN_STAKE + 250e6);
        assertEq(registry.totalStaked(), MIN_STAKE + 250e6);
        assertEq(usdc.balanceOf(address(registry)), MIN_STAKE + 250e6);
    }

    function test_DepositStake_RevertsZero() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(IProviderRegistry.ZeroAmount.selector);
        registry.depositStake(0);
    }

    function test_DepositStake_RevertsUnregistered() public {
        _fund(attacker, MIN_STAKE);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, attacker));
        registry.depositStake(MIN_STAKE);
    }

    function test_DepositStake_RevertsWithPendingUnstake() public {
        _register(alice, MIN_STAKE);
        _fund(alice, 1e6);
        vm.startPrank(alice);
        registry.requestUnstake();
        vm.expectRevert(
            abi.encodeWithSelector(IProviderRegistry.UnstakePending.selector, uint64(block.timestamp) + UNBONDING)
        );
        registry.depositStake(1e6);
        vm.stopPrank();
    }

    function test_DepositStake_RevertsInsufficientBalance() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1e6));
        registry.depositStake(1e6);
        assertEq(_provider(alice).stake, MIN_STAKE, "accounting unchanged after failed transfer");
        assertEq(registry.totalStaked(), MIN_STAKE);
    }

    function test_DepositStake_RevertsOnUint128Overflow() public {
        uint256 big = type(uint128).max;
        vm.prank(admin);
        registry.setMinStake(1);
        _register(alice, big);
        _fund(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, big + 1));
        registry.depositStake(1);
    }

    function test_RequestUnstake() public {
        _eligible(alice, MIN_STAKE);
        uint64 expected = uint64(block.timestamp) + UNBONDING;
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderDeactivated(alice, IProviderRegistry.DeactivationReason.UNSTAKE_REQUESTED);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.UnstakeRequested(alice, MIN_STAKE, expected);
        vm.prank(alice);
        registry.requestUnstake();
        ClinovaTypes.Provider memory p = _provider(alice);
        assertEq(p.unstakeAvailableAt, expected);
        assertFalse(p.active);
        assertFalse(registry.isEligible(alice, CBC));
        assertEq(p.stake, MIN_STAKE, "stake stays until withdrawal");
    }

    function test_RequestUnstake_RevertsTwice() public {
        _register(alice, MIN_STAKE);
        vm.startPrank(alice);
        registry.requestUnstake();
        vm.expectRevert(
            abi.encodeWithSelector(IProviderRegistry.UnstakePending.selector, uint64(block.timestamp) + UNBONDING)
        );
        registry.requestUnstake();
        vm.stopPrank();
    }

    function test_RequestUnstake_RevertsUnregistered() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, attacker));
        registry.requestUnstake();
    }

    function test_RequestUnstake_RevertsWithNoStake() public {
        _register(alice, MIN_STAKE);
        vm.startPrank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        registry.withdrawStake();
        vm.expectRevert(IProviderRegistry.NoStake.selector);
        registry.requestUnstake();
        vm.stopPrank();
    }

    function test_Unbonding_IsSnapshotted() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        registry.requestUnstake();
        uint64 at = _provider(alice).unstakeAvailableAt;
        vm.prank(admin);
        registry.setUnbondingPeriod(30 days);
        assertEq(_provider(alice).unstakeAvailableAt, at, "admin cannot extend a pending unbonding");
        vm.warp(at);
        vm.prank(alice);
        registry.withdrawStake();
    }

    function test_WithdrawStake_Full() public {
        _register(alice, MIN_STAKE * 2);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);

        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ProviderStakeWithdrawn(alice, MIN_STAKE * 2);
        vm.prank(alice);
        registry.withdrawStake();

        ClinovaTypes.Provider memory p = _provider(alice);
        assertEq(p.stake, 0);
        assertEq(p.unstakeAvailableAt, 0);
        assertTrue(p.registered, "record persists; no re-registration");
        assertEq(usdc.balanceOf(alice), MIN_STAKE * 2);
        assertEq(registry.totalStaked(), 0);
        assertEq(usdc.balanceOf(address(registry)), 0);
    }

    function test_WithdrawStake_RevertsBeforeUnbonding() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        registry.requestUnstake();
        uint64 at = _provider(alice).unstakeAvailableAt;
        vm.warp(at - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.UnstakeNotReady.selector, at));
        registry.withdrawStake();
    }

    function test_WithdrawStake_RevertsWithoutRequest() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(IProviderRegistry.NoUnstakeRequested.selector);
        registry.withdrawStake();
    }

    function test_WithdrawStake_RevertsOverWithdrawal() public {
        _register(alice, MIN_STAKE);
        _register(bob, MIN_STAKE); // funds in the contract that alice must not reach
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        vm.startPrank(alice);
        registry.withdrawStake();
        vm.expectRevert(IProviderRegistry.NoUnstakeRequested.selector);
        registry.withdrawStake();
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), MIN_STAKE);
        assertEq(usdc.balanceOf(address(registry)), MIN_STAKE, "bob's stake intact");
        assertEq(_provider(bob).stake, MIN_STAKE);
    }

    function test_WithdrawStake_UnauthorizedCallersGetNothing() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);

        address[5] memory callers = [attacker, admin, verifier, marketplace, pauser];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IProviderRegistry.NoUnstakeRequested.selector);
            registry.withdrawStake();
            assertEq(usdc.balanceOf(callers[i]), 0);
        }
        assertEq(_provider(alice).stake, MIN_STAKE);
    }

    function test_WithdrawStake_RevertsWithActiveObligation() public {
        _eligible(alice, MIN_STAKE);
        vm.prank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ActiveObligation.selector, 1));
        registry.withdrawStake();

        vm.prank(marketplace);
        registry.recordJobClosed(REQ, alice);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(usdc.balanceOf(alice), MIN_STAKE);
    }

    function test_WithdrawStake_ThenRestakeAndReactivate() public {
        _eligible(alice, MIN_STAKE);
        vm.startPrank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        registry.withdrawStake();
        registry.depositStake(MIN_STAKE);
        registry.activate();
        vm.stopPrank();
        assertTrue(registry.isEligible(alice, CBC));
    }

    // ------------------------------------------------------------------
    // Token failure modes
    // ------------------------------------------------------------------

    function test_Token_FalseReturnRevertsAndKeepsAccounting() public {
        FalseReturnToken token = new FalseReturnToken();
        usdc = MockUSDC(address(token));
        registry = _deploy(IERC20(address(token)));
        _register(alice, MIN_STAKE);

        token.setFail(true);
        _fund(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        registry.depositStake(1e6);

        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        registry.withdrawStake();
        assertEq(_provider(alice).stake, MIN_STAKE, "stake not lost on failed transfer");
        assertEq(registry.totalStaked(), MIN_STAKE);

        token.setFail(false);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(token.balanceOf(alice), MIN_STAKE + 1e6);
    }

    function test_Token_FeeOnTransferRejected() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        usdc = MockUSDC(address(token));
        registry = _deploy(IERC20(address(token)));
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProviderRegistry.TransferAmountMismatch.selector, MIN_STAKE, MIN_STAKE - MIN_STAKE / 100
            )
        );
        registry.register(META, LOC, _caps(), MIN_STAKE);
    }

    // ------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------

    function _hookSetup() internal returns (HookToken token, ReentrantProvider rp) {
        token = new HookToken();
        usdc = MockUSDC(address(token));
        registry = _deploy(IERC20(address(token)));
        rp = new ReentrantProvider(registry, IERC20(address(token)));
        token.mint(address(rp), MIN_STAKE * 10);
        rp.register(_caps(), MIN_STAKE);
        token.setHooked(address(rp), true);
    }

    function test_Reentrancy_WithdrawStakeReentryBlocked() public {
        (HookToken token, ReentrantProvider rp) = _hookSetup();
        rp.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        rp.setAttack(ReentrantProvider.Attack.WITHDRAW);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rp.withdrawStake();
        assertEq(registry.getProvider(address(rp)).stake, MIN_STAKE);
        assertEq(token.balanceOf(address(registry)), MIN_STAKE);
    }

    function test_Reentrancy_DepositStakeReentryBlocked() public {
        (HookToken token, ReentrantProvider rp) = _hookSetup();
        rp.setAttack(ReentrantProvider.Attack.DEPOSIT);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rp.depositStake(1e6);
        assertEq(registry.getProvider(address(rp)).stake, MIN_STAKE);
        assertEq(token.balanceOf(address(registry)), registry.totalStaked());
    }

    function test_Reentrancy_HookWithoutAttackStillWorks() public {
        (HookToken token, ReentrantProvider rp) = _hookSetup();
        rp.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        rp.withdrawStake();
        assertEq(token.balanceOf(address(rp)), MIN_STAKE * 10);
    }

    // ------------------------------------------------------------------
    // Marketplace authorization
    // ------------------------------------------------------------------

    uint256 internal constant REQ = 1;

    function test_RecordJobAccepted_ByMarketplace() public {
        _eligible(alice, MIN_STAKE);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IProviderRegistry.JobOpened(REQ, alice, 1);
        vm.prank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);
        assertEq(_provider(alice).activeJobs, 1);
        ClinovaTypes.Job memory job = registry.getJob(REQ);
        assertEq(job.provider, alice);
        assertEq(uint8(job.status), uint8(ClinovaTypes.JobStatus.OPEN));
    }

    function test_RecordJobClosed_ByMarketplace() public {
        _eligible(alice, MIN_STAKE);
        vm.startPrank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IProviderRegistry.JobClosed(REQ, alice, 0);
        registry.recordJobClosed(REQ, alice);
        vm.stopPrank();
        assertEq(_provider(alice).activeJobs, 0);
        assertEq(uint8(registry.getJob(REQ).status), uint8(ClinovaTypes.JobStatus.CLOSED));
    }

    function test_RecordJob_RevertsForNonMarketplace() public {
        _eligible(alice, MIN_STAKE);
        address[5] memory callers = [attacker, admin, verifier, alice, pauser];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
            registry.recordJobAccepted(REQ, alice, CBC);
            vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
            registry.recordJobClosed(REQ, alice);
            vm.stopPrank();
        }
    }

    function test_RecordJobAccepted_RegistryEnforcesEligibility() public {
        // unregistered
        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, bob, CBC));
        registry.recordJobAccepted(REQ, bob, CBC);

        // registered but unverified
        _register(alice, MIN_STAKE);
        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, CBC));
        registry.recordJobAccepted(REQ, alice, CBC);

        // verified but inactive
        vm.prank(verifier);
        registry.verifyProvider(alice);
        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, CBC));
        registry.recordJobAccepted(REQ, alice, CBC);

        // active but service not offered
        vm.prank(alice);
        registry.activate();
        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, GLUCOSE));
        registry.recordJobAccepted(REQ, alice, GLUCOSE);

        // unstaking
        vm.prank(alice);
        registry.requestUnstake();
        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, CBC));
        registry.recordJobAccepted(REQ, alice, CBC);
        assertEq(uint8(registry.getJob(REQ).status), uint8(ClinovaTypes.JobStatus.NONE), "failed calls bind nothing");
    }

    function test_RecordJobAccepted_RevertsWhenRequestAlreadyBound() public {
        _eligible(alice, MIN_STAKE);
        _eligible(bob, MIN_STAKE);
        vm.startPrank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);
        // Same request can never be re-bound: not to another provider, not to the same one, not after closing.
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobAlreadyRecorded.selector, REQ));
        registry.recordJobAccepted(REQ, bob, CBC);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobAlreadyRecorded.selector, REQ));
        registry.recordJobAccepted(REQ, alice, CBC);
        registry.recordJobClosed(REQ, alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobAlreadyRecorded.selector, REQ));
        registry.recordJobAccepted(REQ, alice, CBC);
        vm.stopPrank();
        assertEq(_provider(alice).activeJobs, 0);
        assertEq(_provider(bob).activeJobs, 0);
    }

    function test_RecordJobClosed_RevertsForWrongProvider() public {
        _eligible(alice, MIN_STAKE);
        _eligible(bob, MIN_STAKE);
        vm.startPrank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);
        registry.recordJobAccepted(REQ + 1, bob, CBC);
        // Closing alice's job "as" bob (e.g. to free bob's stake) is rejected.
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobProviderMismatch.selector, REQ, alice, bob));
        registry.recordJobClosed(REQ, bob);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobProviderMismatch.selector, REQ, alice, address(0)));
        registry.recordJobClosed(REQ, address(0));
        vm.stopPrank();
        assertEq(_provider(alice).activeJobs, 1);
        assertEq(_provider(bob).activeJobs, 1);
    }

    function test_RecordJobClosed_RevertsWhenNotOpen() public {
        _eligible(alice, MIN_STAKE);
        vm.startPrank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobNotOpen.selector, REQ));
        registry.recordJobClosed(REQ, alice); // never opened
        registry.recordJobAccepted(REQ, alice, CBC);
        registry.recordJobClosed(REQ, alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobNotOpen.selector, REQ));
        registry.recordJobClosed(REQ, alice); // double close
        vm.stopPrank();
        assertEq(_provider(alice).activeJobs, 0, "activeJobs never goes below zero");
    }

    function test_RecordJobClosed_RevertsUnknownProvider() public {
        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.JobNotOpen.selector, REQ));
        registry.recordJobClosed(REQ, bob);
    }

    function test_Marketplace_CannotActAsProviderOrTouchStake() public {
        _eligible(alice, MIN_STAKE);
        vm.startPrank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, marketplace));
        registry.deactivate();
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotFound.selector, marketplace));
        registry.requestUnstake();
        vm.expectRevert(IProviderRegistry.NoUnstakeRequested.selector);
        registry.withdrawStake();
        vm.stopPrank();
        assertTrue(_provider(alice).active);
        assertEq(_provider(alice).stake, MIN_STAKE);
        assertEq(usdc.balanceOf(marketplace), 0);
    }

    // ------------------------------------------------------------------
    // Admin / roles
    // ------------------------------------------------------------------

    function test_SetMinStake() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IProviderRegistry.ParameterUpdated(registry.MIN_STAKE_KEY(), MIN_STAKE, 1_000e6);
        vm.prank(admin);
        registry.setMinStake(1_000e6);
        assertEq(registry.minStake(), 1_000e6);
    }

    function test_SetMinStake_Bounds() public {
        bytes32 key = registry.MIN_STAKE_KEY();
        uint256 max = registry.MAX_MIN_STAKE();
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ParameterOutOfBounds.selector, key, 0));
        registry.setMinStake(0);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ParameterOutOfBounds.selector, key, max + 1));
        registry.setMinStake(max + 1);
        registry.setMinStake(max);
        vm.stopPrank();
    }

    function test_SetUnbondingPeriod_Bounds() public {
        bytes32 key = registry.UNBONDING_PERIOD_KEY();
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ParameterOutOfBounds.selector, key, 1 days - 1));
        registry.setUnbondingPeriod(1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ParameterOutOfBounds.selector, key, 30 days + 1));
        registry.setUnbondingPeriod(30 days + 1);
        registry.setUnbondingPeriod(1 days);
        registry.setUnbondingPeriod(30 days);
        vm.stopPrank();
    }

    function test_AdminSetters_RevertUnauthorized() public {
        bytes32 role = registry.DEFAULT_ADMIN_ROLE();
        vm.startPrank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier, role)
        );
        registry.setMinStake(1e6);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier, role)
        );
        registry.setUnbondingPeriod(2 days);
        vm.stopPrank();
    }

    function test_Pause_OnlyPauser() public {
        bytes32 role = registry.PAUSER_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        registry.pause();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role)
        );
        registry.pause();

        vm.prank(pauser);
        registry.pause();
        assertTrue(registry.paused());
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role)
        );
        registry.unpause();
        vm.prank(pauser);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_Admin_CannotTakeStake() public {
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        // Even with every role, the admin has no path to another provider's stake.
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), admin);
        registry.grantRole(registry.PAUSER_ROLE(), admin);
        vm.expectRevert(IProviderRegistry.NoUnstakeRequested.selector);
        registry.withdrawStake();
        vm.stopPrank();
        assertEq(usdc.balanceOf(admin), 0);
        assertEq(_provider(alice).stake, MIN_STAKE);
    }

    function test_Admin_CannotGrantMarketplaceCapability() public {
        // Marketplace authority is an immutable address, not a role: no grant makes another caller the marketplace.
        _eligible(alice, MIN_STAKE);
        vm.startPrank(admin);
        registry.grantRole(keccak256("MARKETPLACE_ROLE"), admin);
        vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
        registry.recordJobAccepted(REQ, alice, CBC);
        vm.stopPrank();
    }

    function test_DefaultAdminTransfer_RequiresDelay() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        registry.beginDefaultAdminTransfer(newAdmin);
        (, uint48 schedule) = registry.pendingDefaultAdmin();
        vm.prank(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        registry.acceptDefaultAdminTransfer();
        vm.warp(uint256(schedule) + 1);
        vm.prank(newAdmin);
        registry.acceptDefaultAdminTransfer();
        assertEq(registry.defaultAdmin(), newAdmin);
    }

    // ------------------------------------------------------------------
    // Pause scope
    // ------------------------------------------------------------------

    function test_Pause_BlocksOnlyNewObligations() public {
        _eligible(alice, MIN_STAKE);
        _register(bob, MIN_STAKE);
        vm.prank(marketplace);
        registry.recordJobAccepted(REQ, alice, CBC);
        vm.prank(pauser);
        registry.pause();

        // Blocked
        _fund(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.depositStake(1e6);

        // Not blocked: verification, capability, lifecycle, obligations, exits
        vm.prank(verifier);
        registry.verifyProvider(bob);
        vm.startPrank(bob);
        registry.addCapability(GLUCOSE); // revokes bob's verification
        registry.removeCapability(GLUCOSE);
        vm.stopPrank();
        vm.prank(alice);
        registry.deactivate();
        vm.prank(alice);
        registry.activate();
        vm.prank(marketplace);
        registry.recordJobClosed(REQ, alice);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(usdc.balanceOf(alice), MIN_STAKE + 1e6);
    }
}
