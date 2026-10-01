// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ProviderRegistryBase} from "./ProviderRegistryBase.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";

contract ProviderRegistryFuzzTest is ProviderRegistryBase {
    uint256 internal constant MAX_FUZZ_STAKE = 1e15; // 1 billion USDC

    function _assumeUsableProvider(address who) internal view {
        vm.assume(who != address(0) && who != marketplace && who != address(registry) && who != address(usdc));
        vm.assume(who != verifier && who.code.length == 0 && uint160(who) > 0x10000); // skip precompiles
    }

    /// Stake amounts: registration accepts exactly [minStake, ...] and accounts precisely.
    function testFuzz_Register_StakeAmount(uint256 amount) public {
        amount = bound(amount, 0, MAX_FUZZ_STAKE);
        _fund(alice, amount);
        vm.prank(alice);
        if (amount < MIN_STAKE) {
            vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.InsufficientStake.selector, amount, MIN_STAKE));
            registry.register(META, LOC, _caps(), amount);
            assertEq(usdc.balanceOf(alice), amount);
        } else {
            registry.register(META, LOC, _caps(), amount);
            assertEq(_provider(alice).stake, amount);
            assertEq(registry.totalStaked(), amount);
            assertEq(usdc.balanceOf(address(registry)), amount);
        }
    }

    /// Provider IDs: any EOA-like address can register itself and only ever affects its own record.
    function testFuzz_Register_AnyProviderAddress(address who) public {
        _assumeUsableProvider(who);
        vm.assume(who != alice);
        _register(alice, MIN_STAKE);
        _register(who, MIN_STAKE);
        assertTrue(_provider(who).registered);
        assertFalse(_provider(who).verified);
        assertFalse(_provider(who).active);
        assertEq(_provider(alice).stake, MIN_STAKE);
        assertEq(registry.totalStaked(), 2 * MIN_STAKE);
    }

    /// Hash values: any non-zero commitment is accepted verbatim; zero is rejected.
    function testFuzz_Register_Hashes(bytes32 metadataHash, bytes32 locationHash) public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        if (metadataHash == bytes32(0) || locationHash == bytes32(0)) {
            vm.expectRevert(IProviderRegistry.InvalidHash.selector);
            registry.register(metadataHash, locationHash, _caps(), MIN_STAKE);
        } else {
            registry.register(metadataHash, locationHash, _caps(), MIN_STAKE);
            assertEq(_provider(alice).metadataHash, metadataHash);
            assertEq(_provider(alice).locationHash, locationHash);
        }
    }

    /// Capability identifiers: add/remove round-trips for any non-zero id; zero is rejected.
    function testFuzz_Capability_AddRemove(bytes32 serviceType) public {
        vm.assume(serviceType != CBC && serviceType != MALARIA);
        _register(alice, MIN_STAKE);
        vm.startPrank(alice);
        if (serviceType == bytes32(0)) {
            vm.expectRevert(IProviderRegistry.InvalidCapability.selector);
            registry.addCapability(serviceType);
        } else {
            registry.addCapability(serviceType);
            assertTrue(registry.offersService(alice, serviceType));
            vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.CapabilityAlreadyAdded.selector, serviceType));
            registry.addCapability(serviceType);
            registry.removeCapability(serviceType);
            assertFalse(registry.offersService(alice, serviceType));
            vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.CapabilityNotFound.selector, serviceType));
            registry.removeCapability(serviceType);
        }
        vm.stopPrank();
    }

    /// Eligibility requires the exact capability, for arbitrary service ids.
    function testFuzz_Eligibility_RequiresCapability(bytes32 serviceType) public {
        _eligible(alice, MIN_STAKE);
        bool offered = serviceType == CBC || serviceType == MALARIA;
        assertEq(registry.isEligible(alice, serviceType), offered);
    }

    /// Repeated deposits/withdrawals: provider always gets back exactly what it put in, never more.
    function testFuzz_DepositWithdrawCycles(uint256 seed, uint8 cyclesRaw) public {
        uint256 cycles = bound(cyclesRaw, 1, 8);
        _register(bob, MIN_STAKE); // someone else's funds are present throughout
        uint256 initial = bound(seed, MIN_STAKE, MAX_FUZZ_STAKE);
        _register(alice, initial);

        uint256 totalIn = initial;
        uint256 totalOut;
        for (uint256 i = 0; i < cycles; ++i) {
            uint256 extra = bound(uint256(keccak256(abi.encode(seed, i))), 1, MAX_FUZZ_STAKE);
            _fund(alice, extra);
            vm.prank(alice);
            registry.depositStake(extra);
            totalIn += extra;

            uint256 expected = totalIn - totalOut;
            uint256 before = usdc.balanceOf(alice);
            vm.prank(alice);
            registry.requestUnstake();
            vm.warp(vm.getBlockTimestamp() + UNBONDING);
            vm.prank(alice);
            registry.withdrawStake();
            uint256 received = usdc.balanceOf(alice) - before;
            assertEq(received, expected, "exact stake returned");
            totalOut += received;

            // re-stake for the next cycle
            _fund(alice, MIN_STAKE);
            vm.prank(alice);
            registry.depositStake(MIN_STAKE);
            totalIn += MIN_STAKE;
        }
        assertLe(totalOut, totalIn, "never withdraw more than deposited");
        assertEq(_provider(alice).stake, totalIn - totalOut);
        assertEq(_provider(bob).stake, MIN_STAKE, "other provider untouched");
        assertEq(usdc.balanceOf(address(registry)), registry.totalStaked());
    }

    /// A provider can never withdraw more than its own stake, whatever the other providers hold.
    function testFuzz_WithdrawOnlyOwnStake(uint256 aliceStake, uint256 bobStake) public {
        aliceStake = bound(aliceStake, MIN_STAKE, MAX_FUZZ_STAKE);
        bobStake = bound(bobStake, MIN_STAKE, MAX_FUZZ_STAKE);
        _register(alice, aliceStake);
        _register(bob, bobStake);
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(block.timestamp + UNBONDING);
        vm.prank(alice);
        registry.withdrawStake();
        assertEq(usdc.balanceOf(alice), aliceStake);
        assertEq(usdc.balanceOf(address(registry)), bobStake);
        assertEq(registry.totalStaked(), bobStake);
    }

    /// Any non-verifier caller cannot verify; unverified providers can never activate or become eligible.
    function testFuzz_NonVerifierCannotVerify(address caller) public {
        vm.assume(caller != verifier);
        _register(alice, MIN_STAKE);
        bytes32 role = registry.VERIFIER_ROLE();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
        registry.verifyProvider(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotVerified.selector, alice));
        registry.activate();
        assertFalse(registry.isEligible(alice, CBC));
    }

    /// Any non-marketplace caller cannot record obligations.
    function testFuzz_NonMarketplaceCannotRecordJobs(address caller) public {
        vm.assume(caller != marketplace);
        _eligible(alice, MIN_STAKE);
        vm.startPrank(caller);
        vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
        registry.recordJobAccepted(1, alice, CBC);
        vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
        registry.recordJobClosed(1, alice);
        vm.stopPrank();
    }

    /// Unbonding respects the snapshotted time for arbitrary periods and warp offsets.
    function testFuzz_UnbondingBoundary(uint64 period, uint64 wait) public {
        period = uint64(bound(period, 1 days, 30 days));
        vm.prank(admin);
        registry.setUnbondingPeriod(period);
        _register(alice, MIN_STAKE);
        vm.prank(alice);
        registry.requestUnstake();
        uint64 at = _provider(alice).unstakeAvailableAt;
        wait = uint64(bound(wait, 0, 60 days));
        vm.warp(block.timestamp + wait);
        vm.prank(alice);
        if (wait < period) {
            vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.UnstakeNotReady.selector, at));
            registry.withdrawStake();
        } else {
            registry.withdrawStake();
            assertEq(usdc.balanceOf(alice), MIN_STAKE);
        }
    }
}
