// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ClinovaEscrow} from "../src/ClinovaEscrow.sol";
import {ServiceMarketplace} from "../src/ServiceMarketplace.sol";
import {ProofOfService} from "../src/ProofOfService.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Deploys ProviderRegistry, ClinovaEscrow, ProofOfService, ReputationRegistry and ServiceMarketplace with
///         immutable cross-references, then verifies the whole deployment before returning.
/// @dev Nonce assumption (Phase 5 review): the marketplace address is precomputed as CREATE(deployer, n + 4), where n
///      is the deployer's nonce when `deploy` starts and each `new` below consumes exactly one nonce (one broadcast
///      transaction for an EOA; one CREATE for a contract deployer). It breaks if anything else uses the deployer's
///      nonce in between (a concurrent transaction from the same key, `--resume` after a partial broadcast, or a
///      deployer whose CREATE nonce does not advance by one per deployment). The failure is closed: the
///      marketplace constructor reverts (InvalidWiring) and `verify` re-checks every reference, so a mis-wired system
///      can never come up. A partial deployment leaves orphan modules pointing at an unused address; never use them.
///      Use a fresh deployer key that sends nothing else during the deployment.
///      Roles (VERIFIER_ROLE, PAUSER_ROLE) are granted afterwards by the admin, which should be a multisig.
///
///      ADMIN_ADDRESS=0x... USDC_ADDRESS=0x... forge script script/Deploy.s.sol \
///        --rpc-url arbitrum_sepolia --account <keystore> --broadcast --verify
contract Deploy is Script {
    using SafeCast for uint256;

    uint256 public constant ARBITRUM_SEPOLIA = 421614;
    /// @notice Circle USDC on Arbitrum Sepolia (developers.circle.com/stablecoins/usdc-contract-addresses).
    ///         Only used to check USDC_ADDRESS on chain 421614; contracts never hardcode the token.
    address public constant CIRCLE_USDC_ARBITRUM_SEPOLIA = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    struct Config {
        address admin;
        uint48 adminDelay;
        address usdc;
        uint256 minStake;
        uint64 unbondingPeriod;
        uint256 minPrice;
        uint32 reviewPeriod;
        uint32 disputePeriod;
    }

    struct Deployment {
        ProviderRegistry registry;
        ClinovaEscrow escrow;
        ProofOfService proofOfService;
        ReputationRegistry reputation;
        ServiceMarketplace marketplace;
    }

    function run() external returns (Deployment memory d) {
        // Checked casts: an out-of-range env value reverts instead of silently truncating to a different value.
        Config memory c = Config({
            admin: vm.envAddress("ADMIN_ADDRESS"),
            adminDelay: vm.envOr("ADMIN_DELAY", uint256(2 days)).toUint48(),
            usdc: vm.envAddress("USDC_ADDRESS"),
            minStake: vm.envOr("MIN_STAKE", uint256(100e6)),
            unbondingPeriod: vm.envOr("UNBONDING_PERIOD", uint256(7 days)).toUint64(),
            minPrice: vm.envOr("MIN_PRICE", uint256(1e6)),
            reviewPeriod: vm.envOr("REVIEW_PERIOD", uint256(7 days)).toUint32(),
            disputePeriod: vm.envOr("DISPUTE_PERIOD", uint256(14 days)).toUint32()
        });
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = deploy(c, deployer);
        vm.stopBroadcast();
    }

    /// @param deployer the account whose nonce creates the contracts (broadcaster, or this contract in tests)
    function deploy(Config memory c, address deployer) public returns (Deployment memory d) {
        uint64 nonce = vm.getNonce(deployer);
        address predictedMarketplace = vm.computeCreateAddress(deployer, nonce + 4);

        d.registry = new ProviderRegistry(
            c.admin, c.adminDelay, IERC20(c.usdc), predictedMarketplace, c.minStake, c.unbondingPeriod
        );
        d.escrow = new ClinovaEscrow(IERC20(c.usdc), predictedMarketplace);
        d.proofOfService = new ProofOfService(predictedMarketplace);
        d.reputation = new ReputationRegistry(predictedMarketplace, d.registry, d.proofOfService);
        d.marketplace = new ServiceMarketplace(
            c.admin,
            c.adminDelay,
            d.registry,
            d.escrow,
            d.proofOfService,
            d.reputation,
            c.minPrice,
            c.reviewPeriod,
            c.disputePeriod
        );
        require(address(d.marketplace) == predictedMarketplace, "Deploy: marketplace address mismatch");
        verify(d, c, deployer);
    }

    /// @notice Post-deployment checks. Reverts with a reason on the first mismatch.
    function verify(Deployment memory d, Config memory c, address deployer) public view {
        ServiceMarketplace m = d.marketplace;
        // addresses and code
        require(
            address(d.registry) != address(0) && address(d.escrow) != address(0)
                && address(d.proofOfService) != address(0) && address(d.reputation) != address(0)
                && address(m) != address(0),
            "Deploy: zero address"
        );
        require(address(m).code.length > 0 && address(d.registry).code.length > 0, "Deploy: missing code");
        // marketplace -> modules
        require(address(m.registry()) == address(d.registry), "Deploy: marketplace.registry");
        require(address(m.escrow()) == address(d.escrow), "Deploy: marketplace.escrow");
        require(address(m.proofOfService()) == address(d.proofOfService), "Deploy: marketplace.proofOfService");
        require(address(m.reputation()) == address(d.reputation), "Deploy: marketplace.reputation");
        // modules -> marketplace (immutable single writer)
        require(d.registry.marketplace() == address(m), "Deploy: registry.marketplace");
        require(d.escrow.marketplace() == address(m), "Deploy: escrow.marketplace");
        require(d.proofOfService.marketplace() == address(m), "Deploy: proofOfService.marketplace");
        require(d.reputation.marketplace() == address(m), "Deploy: reputation.marketplace");
        require(address(d.reputation.registry()) == address(d.registry), "Deploy: reputation.registry");
        require(
            address(d.reputation.proofOfService()) == address(d.proofOfService), "Deploy: reputation.proofOfService"
        );
        // token
        require(c.usdc.code.length > 0, "Deploy: token has no code");
        require(
            address(d.registry.usdc()) == c.usdc && address(d.escrow.usdc()) == c.usdc && address(m.usdc()) == c.usdc,
            "Deploy: token mismatch"
        );
        require(IERC20Metadata(c.usdc).decimals() == 6, "Deploy: token decimals");
        if (block.chainid == ARBITRUM_SEPOLIA) {
            require(c.usdc == CIRCLE_USDC_ARBITRUM_SEPOLIA, "Deploy: not Circle USDC on Arbitrum Sepolia");
        }
        // admin and roles: the configured admin only; the deployer keeps nothing; no operational role yet
        require(c.admin != address(0), "Deploy: zero admin");
        require(m.defaultAdmin() == c.admin && d.registry.defaultAdmin() == c.admin, "Deploy: admin");
        require(
            m.defaultAdminDelay() == c.adminDelay && d.registry.defaultAdminDelay() == c.adminDelay,
            "Deploy: admin delay"
        );
        if (deployer != c.admin) {
            require(
                !m.hasRole(m.DEFAULT_ADMIN_ROLE(), deployer)
                    && !d.registry.hasRole(d.registry.DEFAULT_ADMIN_ROLE(), deployer),
                "Deploy: deployer kept admin"
            );
        }
        address[2] memory accounts = [c.admin, deployer];
        for (uint256 i = 0; i < 2; ++i) {
            require(
                !m.hasRole(m.VERIFIER_ROLE(), accounts[i]) && !m.hasRole(m.PAUSER_ROLE(), accounts[i])
                    && !d.registry.hasRole(d.registry.VERIFIER_ROLE(), accounts[i])
                    && !d.registry.hasRole(d.registry.PAUSER_ROLE(), accounts[i]),
                "Deploy: unexpected operational role"
            );
        }
        // parameters
        require(d.registry.minStake() == c.minStake, "Deploy: minStake");
        require(d.registry.unbondingPeriod() == c.unbondingPeriod, "Deploy: unbondingPeriod");
        require(m.minPrice() == c.minPrice, "Deploy: minPrice");
        require(m.reviewPeriod() == c.reviewPeriod, "Deploy: reviewPeriod");
        require(m.disputePeriod() == c.disputePeriod, "Deploy: disputePeriod");
        require(m.nextRequestId() == 1, "Deploy: fresh marketplace");
        require(!m.paused() && !d.registry.paused(), "Deploy: paused");
    }
}
