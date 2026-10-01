// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

abstract contract ProviderRegistryBase is Test {
    uint256 internal constant MIN_STAKE = 500e6; // 500 USDC
    uint64 internal constant UNBONDING = 7 days;
    uint48 internal constant ADMIN_DELAY = 1 days;

    bytes32 internal constant CBC = keccak256("LAB.CBC.V1");
    bytes32 internal constant MALARIA = keccak256("LAB.MALARIA.V1");
    bytes32 internal constant GLUCOSE = keccak256("LAB.GLUCOSE.V1");
    bytes32 internal constant LIPID = keccak256("LAB.LIPID_PROFILE.V1");
    bytes32 internal constant META = keccak256("metadata-commitment");
    bytes32 internal constant LOC = keccak256("region-commitment");

    address internal admin = makeAddr("admin");
    address internal verifier = makeAddr("verifier");
    address internal pauser = makeAddr("pauser");
    address internal marketplace = makeAddr("marketplace");
    address internal alice = makeAddr("alice"); // provider
    address internal bob = makeAddr("bob"); // provider
    address internal attacker = makeAddr("attacker");

    MockUSDC internal usdc;
    ProviderRegistry internal registry;

    function setUp() public virtual {
        usdc = new MockUSDC();
        registry = _deploy(IERC20(address(usdc)));
    }

    function _deploy(IERC20 token) internal returns (ProviderRegistry r) {
        r = new ProviderRegistry(admin, ADMIN_DELAY, token, marketplace, MIN_STAKE, UNBONDING);
        bytes32 verifierRole = r.VERIFIER_ROLE();
        bytes32 pauserRole = r.PAUSER_ROLE();
        vm.startPrank(admin);
        r.grantRole(verifierRole, verifier);
        r.grantRole(pauserRole, pauser);
        vm.stopPrank();
    }

    function _caps() internal pure returns (bytes32[] memory caps) {
        caps = new bytes32[](2);
        caps[0] = CBC;
        caps[1] = MALARIA;
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(registry), type(uint256).max);
    }

    function _register(address who, uint256 stake) internal {
        _fund(who, stake);
        vm.prank(who);
        registry.register(META, LOC, _caps(), stake);
    }

    function _registerVerified(address who, uint256 stake) internal {
        _register(who, stake);
        vm.prank(verifier);
        registry.verifyProvider(who);
    }

    function _eligible(address who, uint256 stake) internal {
        _registerVerified(who, stake);
        vm.prank(who);
        registry.activate();
    }

    function _provider(address who) internal view returns (ClinovaTypes.Provider memory) {
        return registry.getProvider(who);
    }
}
