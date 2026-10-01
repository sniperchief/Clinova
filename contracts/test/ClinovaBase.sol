// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ClinovaEscrow} from "../src/ClinovaEscrow.sol";
import {ServiceMarketplace} from "../src/ServiceMarketplace.sol";
import {ProofOfService} from "../src/ProofOfService.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

/// @notice Full-system fixture: registry + escrow + marketplace deployed through script/Deploy.s.sol.
abstract contract ClinovaBase is Test {
    uint256 internal constant MIN_STAKE = 100e6;
    uint64 internal constant UNBONDING = 7 days;
    uint48 internal constant ADMIN_DELAY = 2 days;
    uint256 internal constant MIN_PRICE = 1e6;
    uint32 internal constant REVIEW = 3 days;
    uint32 internal constant DISPUTE = 14 days;
    uint128 internal constant PRICE = 25e6; // 25 USDC

    bytes32 internal constant CBC = keccak256("LAB.CBC.V1");
    bytes32 internal constant MALARIA = keccak256("LAB.MALARIA.V1");
    bytes32 internal constant GLUCOSE = keccak256("LAB.GLUCOSE.V1");
    bytes32 internal constant REGION = keccak256("region:NG-LA:salt");
    bytes32 internal constant REASON = keccak256("reason-commitment");

    address internal admin = makeAddr("admin");
    address internal verifier = makeAddr("verifier");
    address internal pauser = makeAddr("pauser");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal alice = makeAddr("alice"); // eligible provider
    address internal bob = makeAddr("bob"); // eligible provider
    address internal carol = makeAddr("carol"); // registered, unverified provider
    address internal attacker = makeAddr("attacker");

    MockUSDC internal usdc;
    ProviderRegistry internal registry;
    ClinovaEscrow internal escrow;
    ServiceMarketplace internal market;
    ProofOfService internal pos;
    ReputationRegistry internal rep;
    Deploy internal deployer;

    function setUp() public virtual {
        usdc = new MockUSDC();
        _deploySystem(address(usdc));
        _eligible(alice);
        _eligible(bob);
        _registerProvider(carol);
        _fundBuyer(buyer, 1_000_000e6);
        _fundBuyer(buyer2, 1_000_000e6);
    }

    function _config(address token) internal view returns (Deploy.Config memory) {
        return Deploy.Config({
            admin: admin,
            adminDelay: ADMIN_DELAY,
            usdc: token,
            minStake: MIN_STAKE,
            unbondingPeriod: UNBONDING,
            minPrice: MIN_PRICE,
            reviewPeriod: REVIEW,
            disputePeriod: DISPUTE
        });
    }

    function _deploySystem(address token) internal {
        deployer = new Deploy();
        Deploy.Deployment memory d = deployer.deploy(_config(token), address(deployer));
        registry = d.registry;
        escrow = d.escrow;
        market = d.marketplace;
        pos = d.proofOfService;
        rep = d.reputation;
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        registry.grantRole(registry.PAUSER_ROLE(), pauser);
        market.grantRole(market.VERIFIER_ROLE(), verifier);
        market.grantRole(market.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    // --- providers ---

    function _registerProvider(address p) internal {
        usdc.mint(p, MIN_STAKE);
        vm.startPrank(p);
        usdc.approve(address(registry), MIN_STAKE);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CBC;
        caps[1] = MALARIA;
        registry.register(keccak256(abi.encode("meta", p)), REGION, caps, MIN_STAKE);
        vm.stopPrank();
    }

    function _eligible(address p) internal {
        _registerProvider(p);
        vm.prank(verifier);
        registry.verifyProvider(p);
        vm.prank(p);
        registry.activate();
    }

    // --- buyers / requests ---

    function _fundBuyer(address b, uint256 amount) internal {
        usdc.mint(b, amount);
        vm.prank(b);
        usdc.approve(address(market), type(uint256).max);
    }

    function _deadlines() internal view returns (uint64 acceptDeadline, uint64 serviceDeadline) {
        acceptDeadline = uint64(vm.getBlockTimestamp() + 1 days);
        serviceDeadline = acceptDeadline + 3 days;
    }

    function _create(address b, address directed, uint128 price) internal returns (uint256 id) {
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(b);
        id = market.createRequest(directed, CBC, REGION, price, a, s);
    }

    function _open() internal returns (uint256) {
        return _create(buyer, address(0), PRICE);
    }

    function _accepted(address p) internal returns (uint256 id) {
        id = _open();
        vm.prank(p);
        market.acceptRequest(id);
    }

    function _inService(address p) internal returns (uint256 id) {
        id = _accepted(p);
        vm.prank(p);
        market.startService(id);
    }

    function _proof(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode("CLINOVA_PROOF_V1", id));
    }

    function _completed(address p) internal returns (uint256 id) {
        id = _inService(p);
        vm.prank(p);
        market.submitProof(id, _proof(id));
    }

    function _disputedFromCompleted(address p) internal returns (uint256 id) {
        id = _completed(p);
        vm.prank(buyer);
        market.openDispute(id, REASON);
    }

    // --- views ---

    function _req(uint256 id) internal view returns (ClinovaTypes.ServiceRequest memory) {
        return market.getRequest(id);
    }

    function _status(uint256 id) internal view returns (ClinovaTypes.Status) {
        return market.getRequest(id).status;
    }

    function _escrowState(uint256 id) internal view returns (ClinovaTypes.EscrowState) {
        return escrow.getDeposit(id).state;
    }

    function _activeJobs(address p) internal view returns (uint32) {
        return registry.getProvider(p).activeJobs;
    }

    /// @dev Exact escrow accounting: balance == locked + credited + known donations (not a tautology:
    ///      `donations` is supplied by the test, independently of the contract's own surplus()).
    function _assertEscrowExact(uint256 donations) internal view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalLocked() + escrow.totalCredited() + donations);
        assertEq(escrow.surplus(), donations);
    }
}
