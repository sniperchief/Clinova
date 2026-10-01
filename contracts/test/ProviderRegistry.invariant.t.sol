// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

/// @notice Drives random sequences of provider, verifier, marketplace, admin, pauser and attacker actions.
///         Ghost state is updated only when a call succeeds; invariants compare it with contract state.
contract RegistryHandler is Test {
    ProviderRegistry public immutable registry;
    MockUSDC public immutable usdc;
    address public immutable verifier;
    address public immutable marketplace;
    address public immutable admin;
    address public immutable pauser;
    address public immutable attacker;

    address[4] public actors;
    bytes32[3] internal services = [keccak256("LAB.CBC.V1"), keccak256("LAB.MALARIA.V1"), keccak256("LAB.GLUCOSE.V1")];

    mapping(address => uint256) public ghostMinted;
    mapping(address => uint256) public ghostDeposited;
    mapping(address => uint256) public ghostWithdrawn;
    mapping(address => bool) public ghostRegistered;
    mapping(address => bool) public ghostVerified;
    mapping(address => uint32) public ghostJobs;
    mapping(address => uint256[]) internal openJobIds;
    uint256 public nextJobId = 1;
    uint256 public ghostRegistrations;
    bool public unauthorizedSuccess;
    mapping(bytes32 => uint256) public successes;

    constructor(
        ProviderRegistry registry_,
        MockUSDC usdc_,
        address verifier_,
        address marketplace_,
        address admin_,
        address pauser_
    ) {
        registry = registry_;
        usdc = usdc_;
        verifier = verifier_;
        marketplace = marketplace_;
        admin = admin_;
        pauser = pauser_;
        attacker = makeAddr("inv-attacker");
        for (uint256 i = 0; i < 4; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("inv-provider-", vm.toString(i))));
            vm.prank(actors[i]);
            usdc.approve(address(registry_), type(uint256).max);
        }
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _service(uint256 seed) internal view returns (bytes32) {
        return services[seed % 3];
    }

    enum Want {
        UNVERIFIED,
        VERIFIED,
        ACTIVATABLE,
        ACTIVE,
        UNSTAKABLE,
        UNSTAKING,
        HAS_JOBS
    }

    /// @dev Biases the fuzzer toward actors in a state where the action can succeed, so deep paths
    ///      (verify -> activate -> job -> unstake -> withdraw) are actually reached. Falls back to a random
    ///      actor (usually an expected revert), so invalid calls are still exercised.
    function _pick(uint256 seed, Want want) internal view returns (address) {
        for (uint256 i = 0; i < 4; ++i) {
            address a = actors[(seed % 4 + i) % 4];
            ClinovaTypes.Provider memory p = registry.getProvider(a);
            bool ok;
            if (want == Want.UNVERIFIED) ok = p.registered && !p.verified;
            else if (want == Want.VERIFIED) ok = p.verified;
            else if (want == Want.ACTIVATABLE) ok = p.verified && !p.active && p.unstakeAvailableAt == 0;
            else if (want == Want.ACTIVE) ok = p.active;
            else if (want == Want.UNSTAKABLE) ok = p.registered && p.stake > 0 && p.unstakeAvailableAt == 0;
            else if (want == Want.UNSTAKING) ok = p.unstakeAvailableAt != 0;
            else ok = p.activeJobs > 0;
            if (ok) return a;
        }
        return _actor(seed);
    }

    function _mint(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        ghostMinted[who] += amount;
    }

    // --- provider actions ---

    function register(uint256 actorSeed, uint256 amount, uint256 capSeed) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 1e12);
        _mint(a, amount);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = _service(capSeed);
        vm.prank(a);
        try registry.register(keccak256(abi.encode(a)), keccak256("region"), caps, amount) {
            successes["register"]++;
            ghostRegistered[a] = true;
            ghostDeposited[a] += amount;
            ghostRegistrations++;
        } catch {}
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 0, 1e12);
        _mint(a, amount);
        vm.prank(a);
        try registry.depositStake(amount) {
            successes["deposit"]++;
            ghostDeposited[a] += amount;
        } catch {}
    }

    function updateProfile(uint256 actorSeed, bytes32 meta) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try registry.updateProfile(meta, keccak256("region2")) {
            successes["updateProfile"]++;
            ghostVerified[a] = false;
        } catch {}
    }

    function addCapability(uint256 actorSeed, uint256 capSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try registry.addCapability(_service(capSeed)) {
            successes["addCapability"]++;
            ghostVerified[a] = false;
        } catch {}
    }

    function removeCapability(uint256 actorSeed, uint256 capSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try registry.removeCapability(_service(capSeed)) {} catch {}
    }

    function activate(uint256 actorSeed) external {
        vm.prank(_pick(actorSeed, Want.ACTIVATABLE));
        try registry.activate() {
            successes["activate"]++;
        } catch {}
    }

    function deactivate(uint256 actorSeed) external {
        vm.prank(_pick(actorSeed, Want.ACTIVE));
        try registry.deactivate() {
            successes["deactivate"]++;
        } catch {}
    }

    function requestUnstake(uint256 actorSeed) external {
        vm.prank(_pick(actorSeed, Want.UNSTAKABLE));
        try registry.requestUnstake() {
            successes["requestUnstake"]++;
        } catch {}
    }

    function withdraw(uint256 actorSeed, bool warpToReady) external {
        address a = _pick(actorSeed, Want.UNSTAKING);
        uint64 readyAt = registry.getProvider(a).unstakeAvailableAt;
        if (warpToReady && readyAt > block.timestamp) vm.warp(readyAt);
        uint256 before = usdc.balanceOf(a);
        vm.prank(a);
        try registry.withdrawStake() {
            successes["withdraw"]++;
            ghostWithdrawn[a] += usdc.balanceOf(a) - before;
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 10 days));
    }

    // --- verifier ---

    function verify(uint256 actorSeed) external {
        address a = _pick(actorSeed, Want.UNVERIFIED);
        vm.prank(verifier);
        try registry.verifyProvider(a) {
            successes["verify"]++;
            ghostVerified[a] = true;
        } catch {}
    }

    function revoke(uint256 actorSeed) external {
        address a = _pick(actorSeed, Want.VERIFIED);
        vm.prank(verifier);
        try registry.revokeVerification(a) {
            successes["revoke"]++;
            ghostVerified[a] = false;
        } catch {}
    }

    // --- marketplace ---

    function jobAccepted(uint256 actorSeed, uint256 capSeed) external {
        address a = _actor(actorSeed);
        bytes32 svc = _service(capSeed);
        for (uint256 i = 0; i < 12; ++i) {
            address c = actors[(actorSeed % 4 + i) % 4];
            bytes32 s = services[(capSeed % 3 + i / 4) % 3];
            if (registry.isEligible(c, s)) {
                (a, svc) = (c, s);
                break;
            }
        }
        vm.prank(marketplace);
        uint256 jobId = nextJobId;
        try registry.recordJobAccepted(jobId, a, svc) {
            successes["jobAccepted"]++;
            ghostJobs[a]++;
            openJobIds[a].push(jobId);
            nextJobId++;
        } catch {}
    }

    /// @param wrongProvider if set, try closing the job under a different provider (must always fail).
    function jobClosed(uint256 actorSeed, bool wrongProvider) external {
        address a = _pick(actorSeed, Want.HAS_JOBS);
        uint256 n = openJobIds[a].length;
        uint256 jobId = n == 0 ? nextJobId : openJobIds[a][n - 1];
        address claimed = wrongProvider ? actors[(actorSeed % 4 + 1) % 4] : a;
        vm.prank(marketplace);
        try registry.recordJobClosed(jobId, claimed) {
            if (claimed != a || n == 0) unauthorizedSuccess = true;
            successes["jobClosed"]++;
            ghostJobs[a]--;
            openJobIds[a].pop();
        } catch {}
    }

    // --- admin / pauser ---

    function setMinStake(uint256 value) external {
        vm.prank(admin);
        try registry.setMinStake(bound(value, 1, 2e12)) {} catch {}
    }

    function togglePause() external {
        vm.startPrank(pauser);
        if (registry.paused()) registry.unpause();
        else registry.pause();
        vm.stopPrank();
    }

    // --- attacker: every one of these must fail ---

    function attack(uint256 actorSeed, uint256 which) external {
        address victim = _actor(actorSeed);
        bool ok;
        vm.startPrank(attacker);
        which = which % 5;
        if (which == 0) {
            (ok,) = address(registry).call(abi.encodeCall(registry.withdrawStake, ()));
        } else if (which == 1) {
            (ok,) = address(registry).call(abi.encodeCall(registry.verifyProvider, (victim)));
        } else if (which == 2) {
            (ok,) = address(registry).call(abi.encodeCall(registry.revokeVerification, (victim)));
        } else if (which == 3) {
            (ok,) = address(registry).call(abi.encodeCall(registry.recordJobAccepted, (nextJobId, victim, services[0])));
        } else {
            (ok,) = address(registry).call(abi.encodeCall(registry.recordJobClosed, (1, victim)));
        }
        vm.stopPrank();
        if (ok) unauthorizedSuccess = true;
    }
}

contract ProviderRegistryInvariantTest is Test {
    ProviderRegistry internal registry;
    MockUSDC internal usdc;
    RegistryHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal verifier = makeAddr("verifier");
    address internal pauser = makeAddr("pauser");
    address internal marketplace = makeAddr("marketplace");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ProviderRegistry(admin, 1 days, IERC20(address(usdc)), marketplace, 500e6, 7 days);
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        registry.grantRole(registry.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        handler = new RegistryHandler(registry, usdc, verifier, marketplace, admin, pauser);
        targetContract(address(handler));
    }

    function _p(address a) internal view returns (ClinovaTypes.Provider memory) {
        return registry.getProvider(a);
    }

    /// Stake conservation: token custody equals recorded stake (no donations in this model).
    function invariant_CustodyEqualsTotalStaked() public view {
        assertEq(usdc.balanceOf(address(registry)), registry.totalStaked());
    }

    /// totalStaked is exactly the sum of per-provider stake (nothing counted twice or lost).
    function invariant_TotalEqualsSumOfStakes() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            sum += _p(handler.actors(i)).stake;
        }
        assertEq(sum, registry.totalStaked());
    }

    /// Withdrawal limits: per provider, stake == deposited - withdrawn and withdrawn <= deposited.
    function invariant_PerProviderStakeAccounting() public view {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            uint256 dep = handler.ghostDeposited(a);
            uint256 wd = handler.ghostWithdrawn(a);
            assertLe(wd, dep, "withdrew more than deposited");
            assertEq(_p(a).stake, dep - wd);
        }
    }

    /// No provider ever receives another provider's funds.
    function invariant_WalletBalancesMatchOwnFlows() public view {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(usdc.balanceOf(a), handler.ghostMinted(a) - handler.ghostDeposited(a) + handler.ghostWithdrawn(a));
        }
    }

    /// Privileged and hostile addresses never hold stake tokens.
    function invariant_PrivilegedAddressesHoldNoFunds() public view {
        assertEq(usdc.balanceOf(admin), 0);
        assertEq(usdc.balanceOf(verifier), 0);
        assertEq(usdc.balanceOf(marketplace), 0);
        assertEq(usdc.balanceOf(pauser), 0);
        assertEq(usdc.balanceOf(handler.attacker()), 0);
    }

    /// Provider uniqueness: registration flag matches successful registrations; at most one per address.
    function invariant_ProviderUniqueness() public view {
        uint256 count;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(_p(a).registered, handler.ghostRegistered(a));
            if (_p(a).registered) count++;
        }
        assertEq(count, handler.ghostRegistrations(), "an address registered twice");
    }

    /// Authorization: `verified` only changes through verifier actions (or self-revoking profile/capability edits).
    function invariant_VerifiedOnlyViaVerifier() public view {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(_p(a).verified, handler.ghostVerified(a));
        }
    }

    /// State validity: active => registered && verified && no pending unstake.
    function invariant_ActiveImpliesVerifiedAndNotUnstaking() public view {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            ClinovaTypes.Provider memory p = _p(handler.actors(i));
            if (p.active) {
                assertTrue(p.registered);
                assertTrue(p.verified);
                assertEq(p.unstakeAvailableAt, 0);
            }
            if (!p.registered) {
                assertFalse(p.verified);
                assertEq(p.stake, 0);
            }
        }
    }

    /// Eligibility cannot be reached without every condition holding.
    function invariant_EligibilityRequiresAllConditions() public view {
        bytes32[3] memory svcs = [keccak256("LAB.CBC.V1"), keccak256("LAB.MALARIA.V1"), keccak256("LAB.GLUCOSE.V1")];
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            ClinovaTypes.Provider memory p = _p(a);
            for (uint256 j = 0; j < 3; ++j) {
                if (registry.isEligible(a, svcs[j])) {
                    assertTrue(p.registered && p.verified && p.active);
                    assertTrue(handler.ghostVerified(a), "eligible without verifier approval");
                    assertGe(p.stake, registry.minStake());
                    assertTrue(registry.offersService(a, svcs[j]));
                }
            }
        }
    }

    /// Obligation accounting matches marketplace-recorded jobs exactly.
    function invariant_ActiveJobsMatchMarketplaceRecords() public view {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(_p(a).activeJobs, handler.ghostJobs(a));
        }
    }

    /// No unauthorized call ever succeeded.
    function invariant_NoUnauthorizedSuccess() public view {
        assertFalse(handler.unauthorizedSuccess());
    }

    /// Handler smoke test: the handler's deep paths really succeed, so the invariants above are not vacuous.
    /// (A handler whose calls all revert inside try/catch would pass every invariant trivially.)
    function test_HandlerReachesDeepPaths() public {
        handler.register(0, 1_000e6, 0);
        handler.verify(0);
        handler.activate(0);
        handler.jobAccepted(0, 0);
        handler.requestUnstake(0);
        handler.withdraw(0, true); // blocked by the active obligation
        handler.jobClosed(0, true); // wrong provider: must fail
        handler.jobClosed(0, false);
        handler.withdraw(0, true);
        string[7] memory keys =
            ["register", "verify", "activate", "jobAccepted", "requestUnstake", "jobClosed", "withdraw"];
        for (uint256 i = 0; i < keys.length; ++i) {
            assertEq(handler.successes(bytes32(bytes(keys[i]))), 1, keys[i]);
        }
        assertEq(usdc.balanceOf(handler.actors(0)), 1_000e6);
        invariant_CustodyEqualsTotalStaked();
        invariant_PerProviderStakeAccounting();
        invariant_ActiveJobsMatchMarketplaceRecords();
    }
}
