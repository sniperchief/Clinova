// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

/// @notice Phase 5 §21: deployment script review. Nonce prediction, fail-closed wiring, env parsing and the
///         post-deployment `verify` checks.
contract DeployScriptTest is Test {
    Deploy internal script;
    MockUSDC internal usdc;
    address internal admin = makeAddr("admin");

    function setUp() public {
        script = new Deploy();
        usdc = new MockUSDC();
    }

    function _config() internal view returns (Deploy.Config memory) {
        return Deploy.Config({
            admin: admin,
            adminDelay: 2 days,
            usdc: address(usdc),
            minStake: 100e6,
            unbondingPeriod: 7 days,
            minPrice: 1e6,
            reviewPeriod: 7 days,
            disputePeriod: 14 days
        });
    }

    /// The prediction is relative to the deployer's CURRENT nonce, so earlier activity does not matter.
    function test_Nonce_PredictionHoldsForAnyStartingNonce() public {
        vm.setNonce(address(script), 41);
        Deploy.Deployment memory d = script.deploy(_config(), address(script));
        assertEq(address(d.marketplace), vm.computeCreateAddress(address(script), 45));
        assertEq(address(d.registry), vm.computeCreateAddress(address(script), 41));
        // a second deployment from the same deployer is independent and also verified
        Deploy.Deployment memory d2 = script.deploy(_config(), address(script));
        assertTrue(address(d2.marketplace) != address(d.marketplace));
    }

    /// If the predicted CREATE index is wrong (here: computed from another account's nonce; the same failure as a
    /// concurrent transaction from the deployer key shifting the nonce), the system never comes up: the marketplace
    /// constructor rejects modules that name another marketplace.
    function test_Nonce_MispredictionFailsClosed() public {
        address other = makeAddr("other-deployer");
        vm.setNonce(other, 7);
        vm.expectRevert(IServiceMarketplace.InvalidWiring.selector);
        script.deploy(_config(), other);
    }

    function test_Verify_StandardDeploymentPasses() public {
        Deploy.Deployment memory d = script.deploy(_config(), address(script));
        script.verify(d, _config(), address(script));
        assertEq(d.marketplace.defaultAdmin(), admin);
        assertFalse(d.marketplace.hasRole(d.marketplace.DEFAULT_ADMIN_ROLE(), address(script)));
    }

    function test_Verify_RejectsMismatchedConfig() public {
        Deploy.Deployment memory d = script.deploy(_config(), address(script));
        Deploy.Config memory c = _config();

        c.minStake = 101e6;
        vm.expectRevert(bytes("Deploy: minStake"));
        script.verify(d, c, address(script));

        c = _config();
        c.adminDelay = 1 days;
        vm.expectRevert(bytes("Deploy: admin delay"));
        script.verify(d, c, address(script));

        c = _config();
        c.admin = makeAddr("someone-else");
        vm.expectRevert(bytes("Deploy: admin"));
        script.verify(d, c, address(script));

        c = _config();
        c.usdc = address(new MockUSDC());
        vm.expectRevert(bytes("Deploy: token mismatch"));
        script.verify(d, c, address(script));
    }

    /// A deployment whose modules were swapped is caught even though every contract is individually valid.
    function test_Verify_RejectsSwappedModules() public {
        Deploy.Deployment memory d1 = script.deploy(_config(), address(script));
        Deploy.Deployment memory d2 = script.deploy(_config(), address(script));
        // Memory structs alias on assignment, so each mixed deployment is built field by field.
        Deploy.Deployment memory mixed =
            Deploy.Deployment(d1.registry, d2.escrow, d1.proofOfService, d1.reputation, d1.marketplace);
        vm.expectRevert(bytes("Deploy: marketplace.escrow"));
        script.verify(mixed, _config(), address(script));
        mixed = Deploy.Deployment(d1.registry, d1.escrow, d1.proofOfService, d2.reputation, d1.marketplace);
        vm.expectRevert(bytes("Deploy: marketplace.reputation"));
        script.verify(mixed, _config(), address(script));
    }

    /// Operational roles must not exist at deployment; granting them is a separate, visible admin action.
    function test_Verify_RejectsPregrantedRoles() public {
        Deploy.Deployment memory d = script.deploy(_config(), address(script));
        bytes32 role = d.marketplace.VERIFIER_ROLE();
        vm.prank(admin);
        d.marketplace.grantRole(role, admin);
        vm.expectRevert(bytes("Deploy: unexpected operational role"));
        script.verify(d, _config(), address(script));
    }

    /// On Arbitrum Sepolia the token must be Circle's USDC.
    function test_Verify_RequiresCircleUsdcOnArbitrumSepolia() public {
        vm.chainId(421614);
        vm.expectRevert(bytes("Deploy: not Circle USDC on Arbitrum Sepolia"));
        script.deploy(_config(), address(script));
    }

    /// Env values that do not fit their type now revert instead of silently truncating to a different, valid value
    /// (e.g. REVIEW_PERIOD = 2^32 + 604800 used to become 7 days).
    /// @dev Env vars are process-global and tests run in parallel, so USDC_ADDRESS is only ever set to its real
    ///      production value (Circle's address, with mock token code etched there locally).
    function _setEnv() internal {
        address circle = script.CIRCLE_USDC_ARBITRUM_SEPOLIA();
        vm.etch(circle, address(usdc).code);
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));
        vm.setEnv("USDC_ADDRESS", vm.toString(circle));
    }

    /// Env values that do not fit their type now revert instead of silently truncating to a different, valid value
    /// (e.g. REVIEW_PERIOD = 2^32 + 604800 used to become 7 days); valid values deploy and verify. One test, so the
    /// two REVIEW_PERIOD settings cannot race.
    function test_Run_EnvParsingAndDeploy() public {
        _setEnv();
        uint256 tooBig = uint256(type(uint32).max) + 1 + 7 days;
        vm.setEnv("REVIEW_PERIOD", vm.toString(tooBig));
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, tooBig));
        script.run();

        vm.setEnv("REVIEW_PERIOD", "604800");
        Deploy.Deployment memory d = script.run();
        assertEq(d.marketplace.reviewPeriod(), 7 days);
        assertEq(d.marketplace.disputePeriod(), 14 days);
        assertEq(d.registry.minStake(), 100e6);
        assertEq(address(d.escrow.usdc()), script.CIRCLE_USDC_ARBITRUM_SEPOLIA());
    }
}
