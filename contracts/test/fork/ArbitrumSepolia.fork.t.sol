// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";
import {ClinovaEscrow} from "../../src/ClinovaEscrow.sol";
import {ServiceMarketplace} from "../../src/ServiceMarketplace.sol";
import {ProofOfService} from "../../src/ProofOfService.sol";
import {ReputationRegistry} from "../../src/ReputationRegistry.sol";
import {ClinovaTypes} from "../../src/libraries/ClinovaTypes.sol";

/// @dev The subset of Circle's FiatToken (v2.x) used here. Admin functions are called by pranking the token's own
///      role holders on the fork; balances are created through the token's real mint path, not storage writes.
interface IFiatToken is IERC20Metadata {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 allowance) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
    function pauser() external view returns (address);
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

/// @notice Phase 5 §20: the five contracts against Circle's real USDC on an Arbitrum Sepolia fork.
/// @dev Skipped unless ARB_SEPOLIA_RPC_URL is set. Run:
///        ARB_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc forge test --mc ArbitrumSepoliaForkTest -vv
///      Optional FORK_BLOCK pins the fork. USDC_ADDRESS, if set, must equal Circle's address (checked).
///      Nothing is broadcast: all transactions execute only in the local fork.
contract ArbitrumSepoliaForkTest is Test {
    uint256 internal constant CHAIN_ID = 421614;
    uint256 internal constant PRICE = 25e6;
    bytes32 internal constant CBC = keccak256("LAB.CBC.V1");
    bytes32 internal constant REGION = keccak256("region:NG-LA:salt");

    bool internal forked;
    IFiatToken internal usdc;
    Deploy internal deployer;
    ProviderRegistry internal registry;
    ClinovaEscrow internal escrow;
    ServiceMarketplace internal market;
    ProofOfService internal pos;
    ReputationRegistry internal rep;

    address internal admin = makeAddr("fork-admin");
    address internal verifier = makeAddr("fork-verifier");
    address internal pauser = makeAddr("fork-pauser");
    address internal buyer = makeAddr("fork-buyer");
    address internal provider = makeAddr("fork-provider");

    function setUp() public {
        string memory rpc = vm.envOr("ARB_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;
        assertEq(block.chainid, CHAIN_ID, "not Arbitrum Sepolia");

        deployer = new Deploy();
        address circle = deployer.CIRCLE_USDC_ARBITRUM_SEPOLIA();
        assertEq(vm.envOr("USDC_ADDRESS", circle), circle, "USDC_ADDRESS differs from Circle's documented address");
        usdc = IFiatToken(circle);
        assertGt(address(usdc).code.length, 0, "no code at USDC");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertFalse(usdc.paused(), "USDC is paused on the fork");

        // Deploy through the production script path; verify() enforces Circle USDC on chain 421614.
        Deploy.Deployment memory d = deployer.deploy(
            Deploy.Config({
                admin: admin,
                adminDelay: 2 days,
                usdc: circle,
                minStake: 100e6,
                unbondingPeriod: 7 days,
                minPrice: 1e6,
                reviewPeriod: 7 days,
                disputePeriod: 14 days
            }),
            address(deployer)
        );
        (registry, escrow, market, pos, rep) = (d.registry, d.escrow, d.marketplace, d.proofOfService, d.reputation);
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        market.grantRole(market.VERIFIER_ROLE(), verifier);
        market.grantRole(market.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        // Real mint path: the token's masterMinter configures this test as a minter with a bounded allowance.
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), 1_000_000e6);
        _mint(buyer, 10_000e6);
        _mint(provider, 1_000e6);
        console.log("fork block", block.number, "USDC", circle);
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function _mint(address to, uint256 amount) internal {
        assertTrue(usdc.mint(to, amount));
    }

    function _onboardProvider() internal {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CBC;
        vm.startPrank(provider);
        usdc.approve(address(registry), 100e6);
        registry.register(keccak256("meta"), REGION, caps, 100e6); // register + stake
        vm.stopPrank();
        vm.prank(verifier);
        registry.verifyProvider(provider);
        vm.prank(provider);
        registry.activate();
        assertTrue(registry.isEligible(provider, CBC));
    }

    function _createRequest() internal returns (uint256 id) {
        vm.startPrank(buyer);
        usdc.approve(address(market), PRICE);
        uint64 a = uint64(vm.getBlockTimestamp() + 1 days);
        id = market.createRequest(address(0), CBC, REGION, uint128(PRICE), a, a + 3 days); // create + fund
        vm.stopPrank();
    }

    function _toCompleted() internal returns (uint256 id) {
        id = _createRequest();
        vm.startPrank(provider);
        market.acceptRequest(id);
        market.startService(id);
        market.submitProof(id, keccak256(abi.encode("evidence", id)));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Flows
    // ------------------------------------------------------------------

    /// register -> stake -> verify/activate -> create -> fund -> accept -> start -> proof -> verifier approve ->
    /// release -> withdraw -> reputation -> unstake -> stake withdrawal, all against real USDC.
    function test_Fork_FullFlow_VerifierApproval() public onlyFork {
        uint256 buyerStart = usdc.balanceOf(buyer);
        uint256 providerStart = usdc.balanceOf(provider);
        _onboardProvider();
        assertEq(usdc.balanceOf(address(registry)), 100e6, "stake held by registry");

        uint256 id = _toCompleted();
        assertEq(usdc.balanceOf(address(escrow)), PRICE, "escrow holds the real USDC");
        vm.prank(verifier);
        market.approveProof(id);
        assertEq(uint8(market.getRequest(id).status), uint8(ClinovaTypes.Status.SETTLED));
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.APPROVED));
        assertEq(escrow.credit(provider), PRICE);

        vm.prank(provider);
        escrow.withdraw();
        ClinovaTypes.Reputation memory r = rep.getReputation(provider);
        assertEq(r.completedJobs, 1);
        assertEq(r.successfulJobs, 1);

        vm.prank(provider);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(provider);
        registry.withdrawStake();

        assertEq(usdc.balanceOf(provider), providerStart + PRICE, "provider: stake back + payment");
        assertEq(usdc.balanceOf(buyer), buyerStart - PRICE, "buyer paid exactly the price");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(address(registry)), 0);
    }

    function test_Fork_BuyerConfirms() public onlyFork {
        _onboardProvider();
        uint256 id = _toCompleted();
        vm.prank(buyer);
        market.confirmCompletion(id);
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.BUYER_ACCEPTED));
        vm.prank(provider);
        assertEq(escrow.withdraw(), PRICE);
    }

    /// Refund paths with real USDC: verifier dispute resolution (provider fault), dispute timeout, and an
    /// unreviewed completion closed after the review window (refund, never payment).
    function test_Fork_RefundAndDisputePaths() public onlyFork {
        _onboardProvider();
        uint256 buyerStart = usdc.balanceOf(buyer);
        uint256 fault = _toCompleted();
        uint256 timedOut = _toCompleted();
        uint256 unreviewed = _toCompleted();
        vm.startPrank(buyer);
        market.openDispute(fault, keccak256("not received"));
        market.openDispute(timedOut, keccak256("not received"));
        vm.stopPrank();
        vm.prank(verifier);
        market.resolveDispute(fault, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        vm.warp(vm.getBlockTimestamp() + 15 days);
        market.resolveDisputeByTimeout(timedOut);
        market.closeUnreviewed(unreviewed);

        vm.prank(buyer);
        assertEq(escrow.withdraw(), 3 * PRICE);
        assertEq(usdc.balanceOf(buyer), buyerStart, "buyer made whole");
        assertEq(escrow.credit(provider), 0, "provider never paid without positive acceptance");
        ClinovaTypes.Reputation memory r = rep.getReputation(provider);
        assertEq(r.failedJobs, 1);
        assertEq(r.disputes, 2);
        assertEq(r.completedJobs, 3);
        assertEq(registry.getProvider(provider).activeJobs, 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// Circle's real blacklist: a blacklisted provider is still credited (pull payment) and withdraws its own
    /// credit to another address with withdrawTo.
    function test_Fork_RealBlacklist_WithdrawTo() public onlyFork {
        _onboardProvider();
        uint256 id = _toCompleted();
        vm.prank(usdc.blacklister());
        usdc.blacklist(provider);
        assertTrue(usdc.isBlacklisted(provider));
        vm.prank(verifier);
        market.approveProof(id); // settlement unaffected
        vm.prank(provider);
        vm.expectRevert(); // FiatToken: "Blacklistable: account is blacklisted"
        escrow.withdraw();
        address cold = makeAddr("fork-provider-cold");
        vm.prank(provider);
        escrow.withdrawTo(cold);
        assertEq(usdc.balanceOf(cold), PRICE);
    }

    /// Circle's real pause: lifecycle transitions continue (they never move tokens); withdrawals wait.
    function test_Fork_RealTokenPause() public onlyFork {
        _onboardProvider();
        uint256 id = _toCompleted();
        vm.prank(usdc.pauser());
        usdc.pause();
        vm.prank(buyer);
        market.confirmCompletion(id);
        vm.prank(provider);
        vm.expectRevert(); // FiatToken: "Pausable: paused"
        escrow.withdraw();
        vm.prank(usdc.pauser());
        usdc.unpause();
        vm.prank(provider);
        assertEq(escrow.withdraw(), PRICE);
    }

    /// Real USDC sent straight to the escrow is inert surplus.
    function test_Fork_DirectTransferIsSurplus() public onlyFork {
        vm.prank(buyer);
        assertTrue(usdc.transfer(address(escrow), 3e6));
        assertEq(escrow.surplus(), 3e6);
        assertEq(escrow.totalLocked() + escrow.totalCredited(), 0);
    }
}
