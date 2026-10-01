// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ClinovaBase} from "./ClinovaBase.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ClinovaEscrow} from "../src/ClinovaEscrow.sol";
import {ServiceMarketplace} from "../src/ServiceMarketplace.sol";
import {ProofOfService} from "../src/ProofOfService.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IProofOfService} from "../src/interfaces/IProofOfService.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IClinovaEscrow} from "../src/interfaces/IClinovaEscrow.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {MockUSDC, FeeOnTransferToken, FalseReturnToken, HookToken, ITokenReceiverHook} from "./mocks/Mocks.sol";

/// @notice A buyer contract that re-enters the marketplace from a token hook.
contract ReentrantBuyer is ITokenReceiverHook {
    ServiceMarketplace public immutable market;
    uint8 public mode; // 0 none, 1 re-create during funding, 2 cancel another request during withdraw
    uint256 public target;

    constructor(ServiceMarketplace m, IERC20 token) {
        market = m;
        token.approve(address(m), type(uint256).max);
    }

    function setMode(uint8 m, uint256 t) external {
        mode = m;
        target = t;
    }

    function create(uint64 a, uint64 s) external returns (uint256) {
        return market.createRequest(address(0), keccak256("LAB.CBC.V1"), keccak256("r"), 25e6, a, s);
    }

    function cancel(uint256 id) external {
        market.cancelRequest(id);
    }

    function withdraw() external {
        market.escrow().withdraw();
    }

    function onTokenTransfer() external {
        uint8 m = mode;
        mode = 0;
        if (m == 1) {
            market.createRequest(
                address(0),
                keccak256("LAB.CBC.V1"),
                keccak256("r"),
                25e6,
                uint64(block.timestamp + 1 days),
                uint64(block.timestamp + 4 days)
            );
        } else if (m == 2) {
            market.cancelRequest(target);
        }
    }
}

contract ServiceMarketplaceTest is ClinovaBase {
    // ------------------------------------------------------------------
    // Construction / wiring
    // ------------------------------------------------------------------

    function test_Constructor_State() public view {
        assertEq(address(market.registry()), address(registry));
        assertEq(address(market.escrow()), address(escrow));
        assertEq(address(market.usdc()), address(usdc));
        assertEq(registry.marketplace(), address(market));
        assertEq(escrow.marketplace(), address(market));
        assertEq(market.minPrice(), MIN_PRICE);
        assertEq(market.reviewPeriod(), REVIEW);
        assertEq(market.disputePeriod(), DISPUTE);
        assertEq(market.nextRequestId(), 1);
        assertEq(market.defaultAdmin(), admin);
    }

    /// @dev Next contract created by this test contract after the four modules (registry, escrow, pos, rep).
    function _predictMarket() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
    }

    function _modulesFor(address predictedMarket, address registryToken, address escrowToken)
        internal
        returns (ProviderRegistry r2, ClinovaEscrow e2, ProofOfService p2, ReputationRegistry rep2)
    {
        r2 = new ProviderRegistry(admin, 1 days, IERC20(registryToken), predictedMarket, MIN_STAKE, 7 days);
        e2 = new ClinovaEscrow(IERC20(escrowToken), predictedMarket);
        p2 = new ProofOfService(predictedMarket);
        rep2 = new ReputationRegistry(predictedMarket, r2, p2);
    }

    function test_Constructor_ValidFreshWiring() public {
        address predicted = _predictMarket();
        (ProviderRegistry r2, ClinovaEscrow e2, ProofOfService p2, ReputationRegistry rep2) =
            _modulesFor(predicted, address(usdc), address(usdc));
        ServiceMarketplace m2 = new ServiceMarketplace(admin, 1 days, r2, e2, p2, rep2, MIN_PRICE, REVIEW, DISPUTE);
        assertEq(address(m2), predicted);
        assertEq(address(m2.proofOfService()), address(p2));
        assertEq(address(m2.reputation()), address(rep2));
    }

    function test_Constructor_RevertsOnModulesForOtherMarketplace() public {
        (ProviderRegistry r2, ClinovaEscrow e2, ProofOfService p2, ReputationRegistry rep2) =
            _modulesFor(attacker, address(usdc), address(usdc));
        vm.expectRevert(IServiceMarketplace.InvalidWiring.selector);
        new ServiceMarketplace(admin, 1 days, r2, e2, p2, rep2, MIN_PRICE, REVIEW, DISPUTE);
    }

    function test_Constructor_RevertsOnReusedModules() public {
        // Already-wired modules belong to the existing marketplace, not a new one.
        vm.expectRevert(IServiceMarketplace.InvalidWiring.selector);
        new ServiceMarketplace(admin, 1 days, registry, escrow, pos, rep, MIN_PRICE, REVIEW, DISPUTE);
    }

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(IServiceMarketplace.ZeroAddress.selector);
        new ServiceMarketplace(
            admin, 1 days, IProviderRegistry(address(0)), escrow, pos, rep, MIN_PRICE, REVIEW, DISPUTE
        );
    }

    function test_Constructor_RevertsOnZeroEscrow() public {
        vm.expectRevert(IServiceMarketplace.ZeroAddress.selector);
        new ServiceMarketplace(
            admin, 1 days, registry, IClinovaEscrow(address(0)), pos, rep, MIN_PRICE, REVIEW, DISPUTE
        );
    }

    function test_Constructor_RevertsOnZeroProofOfService() public {
        vm.expectRevert(IServiceMarketplace.ZeroAddress.selector);
        new ServiceMarketplace(
            admin, 1 days, registry, escrow, IProofOfService(address(0)), rep, MIN_PRICE, REVIEW, DISPUTE
        );
    }

    function test_Constructor_RevertsOnZeroReputation() public {
        vm.expectRevert(IServiceMarketplace.ZeroAddress.selector);
        new ServiceMarketplace(
            admin, 1 days, registry, escrow, pos, IReputationRegistry(address(0)), MIN_PRICE, REVIEW, DISPUTE
        );
    }

    function test_Constructor_RevertsOnTokenMismatch() public {
        MockUSDC other = new MockUSDC();
        address predicted = _predictMarket();
        (ProviderRegistry r2, ClinovaEscrow e2, ProofOfService p2, ReputationRegistry rep2) =
            _modulesFor(predicted, address(usdc), address(other));
        vm.expectRevert(IServiceMarketplace.InvalidWiring.selector);
        new ServiceMarketplace(admin, 1 days, r2, e2, p2, rep2, MIN_PRICE, REVIEW, DISPUTE);
    }

    function test_Constructor_RevertsWhenReputationReadsAnotherRegistry() public {
        address predicted = _predictMarket();
        ProviderRegistry r2 = new ProviderRegistry(admin, 1 days, IERC20(address(usdc)), predicted, MIN_STAKE, 7 days);
        ClinovaEscrow e2 = new ClinovaEscrow(IERC20(address(usdc)), predicted);
        ProofOfService p2 = new ProofOfService(predicted);
        ReputationRegistry rep2 = new ReputationRegistry(predicted, registry, p2); // wrong registry
        vm.expectRevert(IServiceMarketplace.InvalidWiring.selector);
        new ServiceMarketplace(admin, 1 days, r2, e2, p2, rep2, MIN_PRICE, REVIEW, DISPUTE);
    }

    function test_Constructor_RevertsWhenReputationReadsAnotherProofModule() public {
        address predicted = _predictMarket();
        ProviderRegistry r2 = new ProviderRegistry(admin, 1 days, IERC20(address(usdc)), predicted, MIN_STAKE, 7 days);
        ClinovaEscrow e2 = new ClinovaEscrow(IERC20(address(usdc)), predicted);
        ProofOfService p2 = new ProofOfService(predicted);
        ReputationRegistry rep2 = new ReputationRegistry(predicted, r2, pos); // wrong proof module
        vm.expectRevert(IServiceMarketplace.InvalidWiring.selector);
        new ServiceMarketplace(admin, 1 days, r2, e2, p2, rep2, MIN_PRICE, REVIEW, DISPUTE);
    }

    function test_Constructor_RevertsOnParamsOutOfBounds() public {
        address predicted = _predictMarket();
        (ProviderRegistry r2, ClinovaEscrow e2, ProofOfService p2, ReputationRegistry rep2) =
            _modulesFor(predicted, address(usdc), address(usdc));
        bytes32 key = market.MIN_PRICE_KEY();
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ParameterOutOfBounds.selector, key, 0));
        new ServiceMarketplace(admin, 1 days, r2, e2, p2, rep2, 0, REVIEW, DISPUTE);
    }

    // ------------------------------------------------------------------
    // Creation + funding
    // ------------------------------------------------------------------

    function test_Create_Valid() public {
        (uint64 a, uint64 s) = _deadlines();
        vm.expectEmit(true, true, true, true, address(market));
        emit IServiceMarketplace.ServiceRequestCreated(1, buyer, address(0), CBC, REGION, PRICE, a, s);
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestFunded(1, buyer, PRICE);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IClinovaEscrow.FundsLocked(1, buyer, PRICE);
        vm.prank(buyer);
        uint256 id = market.createRequest(address(0), CBC, REGION, PRICE, a, s);

        assertEq(id, 1);
        assertEq(market.nextRequestId(), 2);
        ClinovaTypes.ServiceRequest memory r = _req(id);
        assertEq(r.buyer, buyer);
        assertEq(r.provider, address(0));
        assertEq(uint8(r.status), uint8(ClinovaTypes.Status.OPEN));
        assertEq(r.serviceType, CBC);
        assertEq(r.locationHash, REGION);
        assertEq(r.price, PRICE);
        assertEq(r.acceptDeadline, a);
        assertEq(r.serviceDeadline, s);
        assertEq(r.createdAt, block.timestamp);
        assertEq(r.reviewPeriod, REVIEW);
        assertEq(r.disputePeriod, DISPUTE);

        ClinovaTypes.Deposit memory d = escrow.getDeposit(id);
        assertEq(d.payer, buyer);
        assertEq(d.amount, PRICE, "escrow amount equals price");
        assertEq(uint8(d.state), uint8(ClinovaTypes.EscrowState.FUNDED));
        assertEq(usdc.balanceOf(address(escrow)), PRICE);
        assertEq(usdc.balanceOf(address(market)), 0, "marketplace never holds funds");
        _assertEscrowExact(0);
    }

    function test_Create_IdsAreUniqueAndSequential() public {
        uint256 a = _open();
        uint256 b = _create(buyer2, address(0), PRICE);
        uint256 c = _create(buyer, bob, 50e6);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);
        assertEq(_req(b).buyer, buyer2);
        assertEq(escrow.totalLocked(), 2 * PRICE + 50e6);
        assertEq(_status(0) == ClinovaTypes.Status.NONE, true, "id 0 never exists");
    }

    function test_Create_RevertsZeroAndLowPrice() public {
        (uint64 a, uint64 s) = _deadlines();
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.PriceTooLow.selector, 0, MIN_PRICE));
        market.createRequest(address(0), CBC, REGION, 0, a, s);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.PriceTooLow.selector, MIN_PRICE - 1, MIN_PRICE));
        market.createRequest(address(0), CBC, REGION, uint128(MIN_PRICE - 1), a, s);
        vm.stopPrank();
    }

    function test_Create_RevertsInvalidHashes() public {
        (uint64 a, uint64 s) = _deadlines();
        vm.startPrank(buyer);
        vm.expectRevert(IServiceMarketplace.InvalidServiceType.selector);
        market.createRequest(address(0), bytes32(0), REGION, PRICE, a, s);
        vm.expectRevert(IServiceMarketplace.InvalidHash.selector);
        market.createRequest(address(0), CBC, bytes32(0), PRICE, a, s);
        vm.stopPrank();
    }

    function test_Create_RevertsInvalidDeadlines() public {
        uint64 t = uint64(block.timestamp);
        vm.startPrank(buyer);
        // accept window too short / too long
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, t + 1 hours - 1, t + 2 days);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, t + 7 days + 1, t + 10 days);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, t, t + 1 days); // already "now"
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, 0, 0);
        // service window too short / too long
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, t + 1 days, t + 1 days + 6 hours - 1);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, t + 1 days, t + 31 days + 1);
        vm.expectRevert(IServiceMarketplace.InvalidDeadlines.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, t + 1 days, type(uint64).max);
        // exact bounds are accepted
        market.createRequest(address(0), CBC, REGION, PRICE, t + 1 hours, t + 1 hours + 6 hours);
        market.createRequest(address(0), CBC, REGION, PRICE, t + 7 days, t + 37 days);
        vm.stopPrank();
    }

    function test_Create_RevertsDirectedToSelf() public {
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(IServiceMarketplace.BuyerCannotAccept.selector);
        market.createRequest(buyer, CBC, REGION, PRICE, a, s);
    }

    function test_Create_RevertsWhenPaused() public {
        vm.prank(pauser);
        market.pause();
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
    }

    function test_Funding_RevertsWithoutAllowance() public {
        address b = makeAddr("noAllowance");
        usdc.mint(b, PRICE);
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(b);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(market), 0, PRICE)
        );
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        assertEq(market.nextRequestId(), 1, "nothing created");
    }

    function test_Funding_RevertsInsufficientBalance() public {
        address b = makeAddr("poor");
        _fundBuyer(b, PRICE - 1);
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, b, PRICE - 1, PRICE));
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_Funding_UnauthorizedLockAndDoubleFunding() public {
        uint256 id = _open();
        usdc.mint(address(escrow), PRICE);
        vm.prank(attacker);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.lock(id, attacker, PRICE);
        // Even the marketplace address cannot fund the same request twice.
        vm.prank(address(market));
        vm.expectRevert(
            abi.encodeWithSelector(IClinovaEscrow.InvalidEscrowState.selector, id, ClinovaTypes.EscrowState.FUNDED)
        );
        escrow.lock(id, buyer, PRICE);
        assertEq(escrow.getDeposit(id).amount, PRICE);
        _assertEscrowExact(PRICE); // the extra mint is surplus, not anyone's credit
    }

    function test_Funding_FalseReturningTokenReverts() public {
        FalseReturnToken token = new FalseReturnToken();
        usdc = MockUSDC(address(token));
        _deploySystem(address(token));
        _fundBuyer(buyer, PRICE);
        token.setFail(true);
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        assertEq(market.nextRequestId(), 1);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_Funding_FeeOnTransferRejected() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        usdc = MockUSDC(address(token));
        _deploySystem(address(token));
        _fundBuyer(buyer, PRICE);
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.TransferAmountMismatch.selector, PRICE, PRICE - PRICE / 100)
        );
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
    }

    function test_Funding_ReentrantCreateBlocked() public {
        HookToken token = new HookToken();
        usdc = MockUSDC(address(token));
        _deploySystem(address(token));
        ReentrantBuyer rb = new ReentrantBuyer(market, IERC20(address(token)));
        token.mint(address(rb), 100e6);
        token.setHooked(address(rb), true);
        rb.setMode(1, 0);
        (uint64 a, uint64 s) = _deadlines();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rb.create(a, s);
        assertEq(market.nextRequestId(), 1);
    }

    // ------------------------------------------------------------------
    // Acceptance
    // ------------------------------------------------------------------

    function test_Accept_EligibleProvider() public {
        uint256 id = _open();
        vm.expectEmit(true, true, false, false, address(market));
        emit IServiceMarketplace.ServiceRequestAccepted(id, alice);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IProviderRegistry.JobOpened(id, alice, 1);
        vm.expectEmit(true, true, false, false, address(escrow));
        emit IClinovaEscrow.PayeeAssigned(id, alice);
        vm.prank(alice);
        market.acceptRequest(id);

        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.ACCEPTED));
        assertEq(_req(id).provider, alice);
        assertEq(_req(id).price, PRICE, "acceptance cannot change the price");
        assertEq(_activeJobs(alice), 1);
        assertEq(registry.getJob(id).provider, alice);
        assertEq(escrow.getDeposit(id).payee, alice);
        assertEq(escrow.getDeposit(id).amount, PRICE);
    }

    function test_Accept_ActiveJobsIncrementOncePerRequest() public {
        uint256 a = _open();
        uint256 b = _open();
        vm.startPrank(alice);
        market.acceptRequest(a);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, a, ClinovaTypes.Status.ACCEPTED)
        );
        market.acceptRequest(a);
        market.acceptRequest(b);
        vm.stopPrank();
        assertEq(_activeJobs(alice), 2);
    }

    function test_Accept_RevertsUnverifiedProvider() public {
        uint256 id = _open();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, carol, CBC));
        market.acceptRequest(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.OPEN), "failed acceptance changes nothing");
        assertEq(_req(id).provider, address(0));
    }

    function test_Accept_RevertsInactiveProvider() public {
        uint256 id = _open();
        vm.prank(alice);
        registry.deactivate();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, CBC));
        market.acceptRequest(id);
    }

    function test_Accept_RevertsInsufficientStake() public {
        uint256 id = _open();
        vm.prank(admin);
        registry.setMinStake(MIN_STAKE + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, CBC));
        market.acceptRequest(id);
    }

    function test_Accept_RevertsMissingCapability() public {
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        uint256 id = market.createRequest(address(0), GLUCOSE, REGION, PRICE, a, s);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, alice, GLUCOSE));
        market.acceptRequest(id);
    }

    function test_Accept_RevertsUnregisteredAndUnstaking() public {
        uint256 id = _open();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, attacker, CBC));
        market.acceptRequest(id);
        vm.prank(bob);
        registry.requestUnstake();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IProviderRegistry.ProviderNotEligible.selector, bob, CBC));
        market.acceptRequest(id);
    }

    function test_Accept_DeadlineBoundary() public {
        uint256 id = _open();
        uint64 a = _req(id).acceptDeadline;
        vm.warp(a); // exactly at the deadline: still allowed
        vm.prank(alice);
        market.acceptRequest(id);

        uint256 id2 = _open();
        uint64 a2 = _req(id2).acceptDeadline;
        vm.warp(a2 + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, a2));
        market.acceptRequest(id2);
    }

    function test_Accept_BuyerCannotAcceptOwnRequest() public {
        // Buyer that is also an eligible provider.
        _fundBuyer(alice, PRICE);
        uint256 id = _create(alice, address(0), PRICE);
        vm.prank(alice);
        vm.expectRevert(IServiceMarketplace.BuyerCannotAccept.selector);
        market.acceptRequest(id);
    }

    function test_Accept_DirectedRequest() public {
        uint256 id = _create(buyer, bob, PRICE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, id));
        market.acceptRequest(id);
        vm.prank(bob);
        market.acceptRequest(id);
        assertEq(_req(id).provider, bob);
        assertEq(_activeJobs(alice), 0);
        assertEq(_activeJobs(bob), 1);
    }

    function test_Accept_RevertsNonexistentAndPaused() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, 99, ClinovaTypes.Status.NONE)
        );
        market.acceptRequest(99);
        uint256 id = _open();
        vm.prank(pauser);
        market.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.acceptRequest(id);
    }

    function test_Accept_MarketplaceCannotAssignArbitraryProvider() public {
        // The only binding path is acceptRequest (provider = msg.sender). Direct module calls by anyone else fail.
        uint256 id = _open();
        vm.startPrank(attacker);
        vm.expectRevert(IProviderRegistry.OnlyMarketplace.selector);
        registry.recordJobAccepted(id, alice, CBC);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.assignPayee(id, attacker);
        vm.stopPrank();
        assertEq(_activeJobs(alice), 0);
        assertEq(escrow.getDeposit(id).payee, address(0));
    }

    // ------------------------------------------------------------------
    // Start / proof
    // ------------------------------------------------------------------

    function test_Start() public {
        uint256 id = _accepted(alice);
        vm.expectEmit(true, true, false, false, address(market));
        emit IServiceMarketplace.ServiceRequestStarted(id, alice);
        vm.prank(alice);
        market.startService(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.IN_SERVICE));
    }

    function test_Start_Reverts() public {
        uint256 id = _accepted(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, id));
        market.startService(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, id));
        market.startService(id);
        uint64 s = _req(id).serviceDeadline;
        vm.warp(s + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, s));
        market.startService(id);

        uint256 open = _open();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, open, ClinovaTypes.Status.OPEN)
        );
        market.startService(open);
    }

    function test_SubmitProof_Completes() public {
        uint256 id = _inService(alice);
        bytes32 h = _proof(id);
        bytes32 proofHash = pos.computeProofHash(id, alice, h);
        uint64 expectedReview = uint64(block.timestamp) + REVIEW;
        vm.expectEmit(true, true, true, true, address(pos));
        emit IProofOfService.ProofSubmitted(id, alice, proofHash, h, uint64(block.timestamp));
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestCompleted(id, alice, proofHash, expectedReview);
        vm.prank(alice);
        market.submitProof(id, h);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.COMPLETED));
        assertEq(_req(id).reviewDeadline, expectedReview);
        ClinovaTypes.ServiceProof memory proof = pos.getProof(id);
        assertEq(proof.provider, alice);
        assertEq(proof.evidenceCommitment, h);
        assertEq(proof.proofHash, proofHash);
        assertEq(uint8(proof.status), uint8(ClinovaTypes.ProofStatus.SUBMITTED));
        assertTrue(pos.evidenceUsed(alice, h));
        assertFalse(pos.evidenceUsed(bob, h));
        assertEq(uint8(_escrowState(id)), uint8(ClinovaTypes.EscrowState.FUNDED), "completion does not pay");
    }

    function test_SubmitProof_Reverts() public {
        uint256 id = _inService(alice);
        vm.startPrank(alice);
        vm.expectRevert(IProofOfService.InvalidCommitment.selector);
        market.submitProof(id, bytes32(0));
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, id));
        market.submitProof(id, _proof(id));

        // Replay of a provider's own commitment on another of its requests.
        uint256 other = _completed(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.EvidenceAlreadyUsed.selector, alice, _proof(other)));
        market.submitProof(id, _proof(other));

        // Must start service first.
        uint256 acc = _accepted(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, acc, ClinovaTypes.Status.ACCEPTED)
        );
        market.submitProof(acc, _proof(acc));

        // After the deadline.
        uint64 s = _req(id).serviceDeadline;
        vm.warp(s + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, s));
        market.submitProof(id, _proof(id));
    }

    function test_SubmitProof_CannotSquatAnotherProvidersCommitment() public {
        uint256 victimJob = _inService(alice);
        uint256 attackerJob = _inService(bob);
        bytes32 victimHash = _proof(victimJob);
        // bob front-runs by committing alice's hash on his own job...
        vm.prank(bob);
        market.submitProof(attackerJob, victimHash);
        // ...which does not block alice.
        vm.prank(alice);
        market.submitProof(victimJob, victimHash);
        assertEq(uint8(_status(victimJob)), uint8(ClinovaTypes.Status.COMPLETED));
    }

    function test_SubmitProof_CannotSubmitTwice() public {
        uint256 id = _completed(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.COMPLETED)
        );
        market.submitProof(id, keccak256("another"));
    }

    // ------------------------------------------------------------------
    // Cancellation
    // ------------------------------------------------------------------

    function test_Cancel_RefundsBuyer() public {
        uint256 id = _open();
        uint256 before = usdc.balanceOf(buyer);
        vm.expectEmit(true, false, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestCancelled(id, PRICE);
        vm.prank(buyer);
        market.cancelRequest(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.CANCELLED));
        assertEq(uint8(_escrowState(id)), uint8(ClinovaTypes.EscrowState.REFUNDED));
        assertEq(escrow.credit(buyer), PRICE);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdc.balanceOf(buyer), before + PRICE, "exact refund");
        _assertEscrowExact(0);
    }

    function test_Cancel_Reverts() public {
        uint256 id = _open();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotBuyer.selector, id));
        market.cancelRequest(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotBuyer.selector, id));
        market.cancelRequest(id);

        vm.prank(buyer);
        market.cancelRequest(id);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.CANCELLED)
        );
        market.cancelRequest(id);
        // Cancelled can never be accepted.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.CANCELLED)
        );
        market.acceptRequest(id);
    }

    function test_Cancel_RevertsAfterAcceptance() public {
        uint256 id = _accepted(alice);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.ACCEPTED)
        );
        market.cancelRequest(id);
    }

    // ------------------------------------------------------------------
    // Expiry
    // ------------------------------------------------------------------

    function test_ExpireOpen_Boundaries() public {
        uint256 id = _open();
        uint64 a = _req(id).acceptDeadline;
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, a));
        market.expireRequest(id);
        vm.warp(a); // exactly at the deadline: not yet
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, a));
        market.expireRequest(id);
        vm.warp(a + 1);
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestExpired(id, attacker, ClinovaTypes.Status.OPEN, PRICE);
        vm.prank(attacker); // anyone: funds can only go to the buyer
        market.expireRequest(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.EXPIRED));
        assertEq(escrow.credit(buyer), PRICE);
        assertEq(escrow.credit(attacker), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.EXPIRED)
        );
        market.expireRequest(id);
    }

    function test_ExpireAccepted_ByBuyer() public {
        uint256 id = _accepted(alice);
        uint64 s = _req(id).serviceDeadline;
        vm.warp(s);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, s));
        market.expireRequest(id);
        vm.warp(s + 1);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IProviderRegistry.JobClosed(id, alice, 0);
        vm.prank(buyer);
        market.expireRequest(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.EXPIRED));
        assertEq(uint8(_escrowState(id)), uint8(ClinovaTypes.EscrowState.REFUNDED));
        assertEq(_activeJobs(alice), 0);
        assertEq(uint8(registry.getJob(id).status), uint8(ClinovaTypes.JobStatus.CLOSED));
        assertEq(escrow.credit(buyer), PRICE);
        assertEq(escrow.credit(alice), 0);
    }

    function test_ExpireInService_ByProvider() public {
        // Liveness: a provider whose buyer disappeared can still close the job to free its stake.
        uint256 id = _inService(alice);
        vm.warp(_req(id).serviceDeadline + 1);
        vm.prank(alice);
        market.expireRequest(id);
        assertEq(_activeJobs(alice), 0);
        assertEq(escrow.credit(buyer), PRICE, "refund still goes to the buyer");
    }

    function test_ExpireAccepted_RevertsForNonParty() public {
        uint256 id = _accepted(alice);
        vm.warp(_req(id).serviceDeadline + 1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotParty.selector, id));
        market.expireRequest(id);
    }

    function test_Expire_WrongStates() public {
        uint256 id = _completed(alice);
        vm.warp(_req(id).serviceDeadline + 1);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.COMPLETED)
        );
        market.expireRequest(id);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, 77, ClinovaTypes.Status.NONE)
        );
        market.expireRequest(77);
    }

    function test_Expire_ProviderCannotSettleAfterwards() public {
        uint256 id = _inService(alice);
        vm.warp(_req(id).serviceDeadline + 1);
        vm.prank(buyer);
        market.expireRequest(id);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.EXPIRED)
        );
        market.submitProof(id, _proof(id));
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.EXPIRED)
        );
        market.confirmCompletion(id);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.EXPIRED)
        );
        market.approveProof(id);
        // Buyer recovers exactly the escrowed amount, once.
        vm.startPrank(buyer);
        assertEq(escrow.withdraw(), PRICE);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    function test_Settle_BuyerConfirms() public {
        uint256 id = _completed(alice);
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestSettled(
            id, alice, PRICE, IServiceMarketplace.SettlementPath.BUYER_CONFIRMED
        );
        vm.prank(buyer);
        market.confirmCompletion(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.SETTLED));
        assertEq(uint8(_escrowState(id)), uint8(ClinovaTypes.EscrowState.RELEASED));
        assertEq(escrow.credit(alice), PRICE);
        assertEq(escrow.credit(buyer), 0);
        assertEq(_activeJobs(alice), 0);
        vm.prank(alice);
        escrow.withdraw();
        assertEq(usdc.balanceOf(alice), PRICE, "provider receives exactly the price");
        _assertEscrowExact(0);
    }

    function test_Settle_OnlyBuyerCanConfirm() public {
        uint256 id = _completed(alice);
        address[4] memory callers = [alice, buyer2, attacker, verifier];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotBuyer.selector, id));
            market.confirmCompletion(id);
        }
    }

    function test_Settle_ConfirmWrongStates() public {
        uint256 open = _open();
        uint256 acc = _accepted(alice);
        uint256 svc = _inService(bob);
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, open, ClinovaTypes.Status.OPEN)
        );
        market.confirmCompletion(open);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, acc, ClinovaTypes.Status.ACCEPTED)
        );
        market.confirmCompletion(acc);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, svc, ClinovaTypes.Status.IN_SERVICE)
        );
        market.confirmCompletion(svc);
        vm.stopPrank();
    }

    function test_Settle_OnlyOnce() public {
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        bytes memory err =
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.SETTLED);
        vm.prank(buyer);
        vm.expectRevert(err);
        market.confirmCompletion(id);
        vm.prank(verifier);
        vm.expectRevert(err);
        market.approveProof(id);
        vm.expectRevert(err);
        market.closeUnreviewed(id);
        vm.prank(buyer);
        vm.expectRevert(err);
        market.openDispute(id, REASON);
        assertEq(escrow.credit(alice), PRICE, "credited exactly once");
    }

    function test_Settle_VerifierApproves() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.approveProof(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.SETTLED));
        assertEq(escrow.credit(alice), PRICE);
    }

    function test_Settle_ApproveRequiresRoleAndNoConflict() public {
        uint256 id = _completed(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role)
        );
        market.approveProof(id);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        market.approveProof(id);
        // A provider that also holds VERIFIER_ROLE cannot approve its own job.
        vm.startPrank(admin);
        market.grantRole(role, alice);
        market.grantRole(role, buyer);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, alice));
        market.approveProof(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, buyer));
        market.approveProof(id);
    }

    /// Phase 4: an unreviewed completion is never paid. After the review window it closes as a no-fault refund.
    function test_CloseUnreviewed_RefundsBuyerNoFault() public {
        uint256 id = _completed(alice);
        uint64 rd = _req(id).reviewDeadline;
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, rd));
        market.closeUnreviewed(id);
        vm.warp(rd);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, rd));
        market.closeUnreviewed(id);
        vm.warp(rd + 1);
        vm.expectEmit(true, true, false, false, address(market));
        emit IServiceMarketplace.CompletionClosedUnreviewed(id, attacker);
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestRefunded(id, buyer, PRICE);
        vm.prank(attacker);
        market.closeUnreviewed(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.REFUNDED));
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.UNRESOLVED));
        assertEq(escrow.credit(buyer), PRICE);
        assertEq(escrow.credit(alice), 0, "unreviewed claim is never paid");
        assertEq(escrow.credit(attacker), 0);
        assertEq(_activeJobs(alice), 0);
        ClinovaTypes.Reputation memory r = rep.getReputation(alice);
        assertEq(r.completedJobs, 1);
        assertEq(r.successfulJobs, 0);
        assertEq(r.failedJobs, 0, "no fault for an unreviewed close");
        assertEq(r.disputes, 0);
    }

    function test_CloseUnreviewed_VerifierCanStillActUntilClosed() public {
        uint256 id = _completed(alice);
        vm.warp(_req(id).reviewDeadline + 5 days);
        vm.prank(verifier);
        market.approveProof(id);
        assertEq(escrow.credit(alice), PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.SETTLED)
        );
        market.closeUnreviewed(id);
    }

    function test_CloseUnreviewed_RequiresCompleted() public {
        uint256 id = _inService(alice);
        vm.warp(block.timestamp + 60 days);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.IN_SERVICE)
        );
        market.closeUnreviewed(id);
    }

    function test_Settle_ReviewPeriodSnapshotted() public {
        uint256 id = _inService(alice);
        vm.prank(admin);
        market.setReviewPeriod(14 days);
        vm.prank(alice);
        market.submitProof(id, _proof(id));
        assertEq(_req(id).reviewDeadline, block.timestamp + REVIEW, "admin change does not affect existing request");
    }

    function test_Settle_AfterRefundFails() public {
        uint256 id = _disputedFromCompleted(alice);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
        bytes memory err =
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.REFUNDED);
        vm.prank(buyer);
        vm.expectRevert(err);
        market.confirmCompletion(id);
        vm.expectRevert(err);
        market.closeUnreviewed(id);
        vm.prank(verifier);
        vm.expectRevert(err);
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        assertEq(escrow.credit(alice), 0);
        assertEq(escrow.credit(buyer), PRICE);
    }

    function test_Settle_PaysTheAcceptingProviderOnly() public {
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        assertEq(escrow.credit(bob), 0);
        assertEq(escrow.credit(alice), PRICE);
        vm.prank(bob);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
    }

    // ------------------------------------------------------------------
    // Disputes
    // ------------------------------------------------------------------

    function test_Dispute_ByBuyerAndProviderInEachState() public {
        uint256 a = _accepted(alice);
        uint256 b = _inService(alice);
        uint256 c = _completed(alice);
        uint256 d = _accepted(bob);
        vm.startPrank(buyer);
        market.openDispute(a, REASON);
        market.openDispute(b, REASON);
        market.openDispute(c, REASON);
        vm.stopPrank();
        vm.prank(bob);
        market.openDispute(d, REASON);
        assertEq(uint8(_req(a).disputedFrom), uint8(ClinovaTypes.Status.ACCEPTED));
        assertEq(uint8(_req(b).disputedFrom), uint8(ClinovaTypes.Status.IN_SERVICE));
        assertEq(uint8(_req(c).disputedFrom), uint8(ClinovaTypes.Status.COMPLETED));
        assertEq(_req(a).disputeDeadline, block.timestamp + DISPUTE);
        assertEq(uint8(_status(d)), uint8(ClinovaTypes.Status.DISPUTED));
        assertEq(uint8(_escrowState(a)), uint8(ClinovaTypes.EscrowState.FUNDED), "funds stay locked in dispute");
    }

    function test_Dispute_Emits() public {
        uint256 id = _accepted(alice);
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestDisputed(
            id, buyer, REASON, ClinovaTypes.Status.ACCEPTED, uint64(block.timestamp) + DISPUTE
        );
        vm.prank(buyer);
        market.openDispute(id, REASON);
    }

    function test_Dispute_Unauthorized() public {
        uint256 a = _accepted(alice);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotParty.selector, a));
        market.openDispute(a, REASON);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotParty.selector, a));
        market.openDispute(a, REASON);
        // Provider cannot dispute its own completed job (it is paid by finalization).
        uint256 c = _completed(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotBuyer.selector, c));
        market.openDispute(c, REASON);
    }

    function test_Dispute_InvalidStateAndInputs() public {
        uint256 open = _open();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, open, ClinovaTypes.Status.OPEN)
        );
        market.openDispute(open, REASON);
        uint256 a = _accepted(alice);
        vm.prank(buyer);
        vm.expectRevert(IServiceMarketplace.InvalidHash.selector);
        market.openDispute(a, bytes32(0));
        vm.prank(buyer);
        market.openDispute(a, REASON);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, a, ClinovaTypes.Status.DISPUTED)
        );
        market.openDispute(a, REASON);
    }

    function test_Dispute_DeadlinesEnforced() public {
        uint256 a = _accepted(alice);
        uint64 s = _req(a).serviceDeadline;
        vm.warp(s + 1);
        vm.prank(alice); // cannot stall a missed deadline with a late dispute
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, s));
        market.openDispute(a, REASON);

        uint256 c = _completed(bob);
        uint64 rd = _req(c).reviewDeadline;
        vm.warp(rd + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, rd));
        market.openDispute(c, REASON);
    }

    function test_RejectProof_ByVerifier() public {
        uint256 id = _completed(alice);
        bytes32 proofHash = pos.getProof(id).proofHash;
        vm.expectEmit(true, true, true, true, address(pos));
        emit IProofOfService.ProofRejected(id, alice, verifier, proofHash, REASON);
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.DISPUTED));
        assertEq(uint8(_req(id).disputedFrom), uint8(ClinovaTypes.Status.COMPLETED));
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.REJECTED));
        assertEq(pos.getProof(id).reviewer, verifier);
    }

    function test_RejectProof_Reverts() public {
        uint256 id = _completed(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, role));
        market.rejectProof(id, REASON);
        vm.prank(verifier);
        vm.expectRevert(IServiceMarketplace.InvalidHash.selector);
        market.rejectProof(id, bytes32(0));
        // Still reviewable after the review deadline, until someone closes it as unreviewed.
        vm.warp(_req(id).reviewDeadline + 1);
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.DISPUTED));
    }

    /// A rejected proof is final: the dispute it opens can never pay the provider.
    function test_RejectedProofCanNeverPay() public {
        uint256 id = _completed(alice);
        vm.prank(verifier);
        market.rejectProof(id, REASON);
        address verifier2 = makeAddr("verifier2");
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(admin);
        market.grantRole(role, verifier2);
        vm.prank(verifier2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IServiceMarketplace.ProofNotApprovable.selector, id, ClinovaTypes.ProofStatus.REJECTED
            )
        );
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.DISPUTED)
        );
        market.confirmCompletion(id);
        vm.warp(_req(id).disputeDeadline + 1);
        market.resolveDisputeByTimeout(id);
        assertEq(escrow.credit(alice), 0);
        assertEq(escrow.credit(buyer), PRICE);
        assertEq(uint8(pos.proofStatus(id)), uint8(ClinovaTypes.ProofStatus.REJECTED), "rejection is not overwritten");
    }

    function test_Dispute_ProofIntoDisputeThenProviderWins() public {
        uint256 id = _inService(alice);
        vm.prank(buyer);
        market.openDispute(id, REASON);
        bytes32 h = _proof(id);
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.DisputeEvidenceSubmitted(id, alice, pos.computeProofHash(id, alice, h));
        vm.prank(alice);
        market.submitProof(id, h);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.DISPUTED), "status unchanged");
        assertEq(pos.getProof(id).evidenceCommitment, h);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProofOfService.ProofAlreadySubmitted.selector, id));
        market.submitProof(id, keccak256("second"));

        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.DisputeResolved(id, verifier, ClinovaTypes.Resolution.PROVIDER_WINS);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.SETTLED));
        assertEq(escrow.credit(alice), PRICE);
        assertEq(_activeJobs(alice), 0);
    }

    function test_Dispute_ProofIntoDisputeRules() public {
        // Not allowed when disputed from COMPLETED (the proof already exists), by another provider, or late.
        uint256 c = _disputedFromCompleted(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, c, ClinovaTypes.Status.DISPUTED)
        );
        market.submitProof(c, keccak256("x"));

        uint256 a = _accepted(bob);
        vm.prank(buyer);
        market.openDispute(a, REASON);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.NotAssignedProvider.selector, a));
        market.submitProof(a, keccak256("y"));
        uint64 s = _req(a).serviceDeadline;
        vm.warp(s + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlinePassed.selector, s));
        market.submitProof(a, keccak256("y"));
    }

    function test_Resolve_ProviderWinsRequiresProof() public {
        uint256 id = _accepted(alice);
        vm.prank(buyer);
        market.openDispute(id, REASON);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.ProofNotApprovable.selector, id, ClinovaTypes.ProofStatus.NONE)
        );
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
    }

    function test_Resolve_RefundOutcomes() public {
        uint256 a = _disputedFromCompleted(alice);
        uint256 b = _disputedFromCompleted(bob);
        vm.startPrank(verifier);
        vm.expectEmit(true, true, false, true, address(market));
        emit IServiceMarketplace.ServiceRequestRefunded(a, buyer, PRICE);
        market.resolveDispute(a, ClinovaTypes.Resolution.REFUND_PROVIDER_FAULT);
        market.resolveDispute(b, ClinovaTypes.Resolution.REFUND_NO_FAULT);
        vm.stopPrank();
        assertEq(uint8(_status(a)), uint8(ClinovaTypes.Status.REFUNDED));
        assertEq(uint8(_status(b)), uint8(ClinovaTypes.Status.REFUNDED));
        assertEq(escrow.credit(buyer), 2 * PRICE);
        assertEq(_activeJobs(alice), 0);
        assertEq(_activeJobs(bob), 0);
    }

    function test_Resolve_AuthorizationAndNoDoubleResolution() public {
        uint256 id = _disputedFromCompleted(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
        vm.prank(admin);
        market.grantRole(role, buyer);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ConflictOfInterest.selector, buyer));
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);

        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.SETTLED)
        );
        market.resolveDispute(id, ClinovaTypes.Resolution.REFUND_NO_FAULT);
    }

    function test_DisputeTimeout_NoPermanentLock() public {
        uint256 id = _disputedFromCompleted(alice);
        uint64 dd = _req(id).disputeDeadline;
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, dd));
        market.resolveDisputeByTimeout(id);
        vm.warp(dd);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.DeadlineNotPassed.selector, dd));
        market.resolveDisputeByTimeout(id);
        vm.warp(dd + 1);
        vm.expectEmit(true, true, false, false, address(market));
        emit IServiceMarketplace.DisputeTimedOut(id, attacker);
        vm.prank(attacker);
        market.resolveDisputeByTimeout(id);
        assertEq(uint8(_status(id)), uint8(ClinovaTypes.Status.REFUNDED));
        assertEq(escrow.credit(buyer), PRICE);
        assertEq(_activeJobs(alice), 0, "provider stake is freed");
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.REFUNDED)
        );
        market.resolveDisputeByTimeout(id);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.InvalidStatus.selector, id, ClinovaTypes.Status.REFUNDED)
        );
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
    }

    function test_DisputeTimeout_VerifierMayStillResolveLate() public {
        uint256 id = _disputedFromCompleted(alice);
        vm.warp(_req(id).disputeDeadline + 10 days);
        vm.prank(verifier);
        market.resolveDispute(id, ClinovaTypes.Resolution.PROVIDER_WINS);
        assertEq(escrow.credit(alice), PRICE);
    }

    function test_DisputeTimeout_WorksWithNoVerifiersAtAll() public {
        uint256 id = _disputedFromCompleted(alice);
        bytes32 role = market.VERIFIER_ROLE();
        vm.prank(admin);
        market.revokeRole(role, verifier);
        vm.warp(_req(id).disputeDeadline + 1);
        market.resolveDisputeByTimeout(id);
        vm.prank(buyer);
        assertEq(escrow.withdraw(), PRICE);
    }

    function test_DisputePeriod_Snapshotted() public {
        uint256 id = _accepted(alice);
        vm.prank(admin);
        market.setDisputePeriod(60 days);
        vm.prank(buyer);
        market.openDispute(id, REASON);
        assertEq(_req(id).disputeDeadline, block.timestamp + DISPUTE);
    }

    // ------------------------------------------------------------------
    // Pause matrix
    // ------------------------------------------------------------------

    function test_Pause_OnlyBlocksNewObligations() public {
        uint256 open1 = _open();
        uint256 open2 = _open();
        uint256 acc = _accepted(alice);
        uint256 svc = _inService(alice);
        uint256 comp1 = _completed(bob);
        uint256 comp2 = _completed(bob);
        uint256 comp3 = _completed(bob);
        uint256 disp1 = _disputedFromCompleted(alice);
        uint256 disp2 = _disputedFromCompleted(alice);
        uint256 toStart = _accepted(bob);
        uint256 toProve = _inService(bob);

        vm.prank(pauser);
        market.pause();
        vm.prank(pauser);
        registry.pause();

        // Blocked
        (uint64 a, uint64 s) = _deadlines();
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.createRequest(address(0), CBC, REGION, PRICE, a, s);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.acceptRequest(open1);

        // Allowed: every in-flight step and every exit
        vm.prank(buyer);
        market.cancelRequest(open1);
        vm.prank(bob);
        market.startService(toStart);
        vm.prank(bob);
        market.submitProof(toProve, _proof(toProve));
        vm.prank(buyer);
        market.confirmCompletion(comp1);
        vm.prank(verifier);
        market.approveProof(comp2);
        vm.prank(buyer);
        market.openDispute(acc, REASON);
        vm.prank(verifier);
        market.resolveDispute(disp1, ClinovaTypes.Resolution.PROVIDER_WINS);

        vm.warp(block.timestamp + 60 days);
        market.expireRequest(open2);
        vm.prank(buyer);
        market.expireRequest(svc);
        market.closeUnreviewed(comp3);
        market.resolveDisputeByTimeout(disp2);
        market.resolveDisputeByTimeout(acc);

        vm.prank(alice);
        escrow.withdraw();
        vm.prank(bob);
        escrow.withdraw();
        vm.prank(buyer);
        escrow.withdraw();
        _assertEscrowExact(0);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function test_Admin_ParameterBoundsAndAuth() public {
        vm.startPrank(admin);
        bytes32 k1 = market.MIN_PRICE_KEY();
        bytes32 k2 = market.REVIEW_PERIOD_KEY();
        bytes32 k3 = market.DISPUTE_PERIOD_KEY();
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ParameterOutOfBounds.selector, k1, 1e6 - 1));
        market.setMinPrice(1e6 - 1);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ParameterOutOfBounds.selector, k1, 10_000e6 + 1));
        market.setMinPrice(10_000e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ParameterOutOfBounds.selector, k2, 1 days - 1));
        market.setReviewPeriod(1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ParameterOutOfBounds.selector, k2, 14 days + 1));
        market.setReviewPeriod(14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ParameterOutOfBounds.selector, k3, 3 days - 1));
        market.setDisputePeriod(3 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.ParameterOutOfBounds.selector, k3, 60 days + 1));
        market.setDisputePeriod(60 days + 1);
        vm.expectEmit(true, false, false, true, address(market));
        emit IServiceMarketplace.ParameterUpdated(k1, MIN_PRICE, 5e6);
        market.setMinPrice(5e6);
        vm.stopPrank();

        bytes32 adminRole = market.DEFAULT_ADMIN_ROLE();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier, adminRole)
        );
        market.setMinPrice(2e6);
        bytes32 pauserRole = market.PAUSER_ROLE();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, pauserRole)
        );
        market.pause();
    }

    function test_Admin_CannotChangeExistingRequestPrice() public {
        uint256 id = _open();
        vm.prank(admin);
        market.setMinPrice(10_000e6);
        assertEq(_req(id).price, PRICE);
        assertEq(escrow.getDeposit(id).amount, PRICE);
        vm.prank(alice);
        market.acceptRequest(id); // still acceptable at its original price
    }

    function test_Admin_HasNoPathToEscrow() public {
        uint256 id = _completed(alice);
        bytes32 v = market.VERIFIER_ROLE();
        bytes32 p = market.PAUSER_ROLE();
        vm.startPrank(admin);
        market.grantRole(v, admin);
        market.grantRole(p, admin);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.release(id);
        vm.expectRevert(IClinovaEscrow.OnlyMarketplace.selector);
        escrow.refund(id);
        vm.expectRevert(IClinovaEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        // With the verifier role, the most it can do is settle to the bound provider.
        market.approveProof(id);
        vm.stopPrank();
        assertEq(usdc.balanceOf(admin), 0);
        assertEq(escrow.credit(admin), 0);
        assertEq(escrow.credit(alice), PRICE);
    }

    function test_EscrowAmountMismatchIsRejected() public {
        // Unreachable with the real escrow; proves the marketplace does not blindly trust module return values.
        uint256 id = _completed(alice);
        vm.mockCall(address(escrow), abi.encodeCall(escrow.release, (id)), abi.encode(PRICE - 1));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IServiceMarketplace.EscrowAmountMismatch.selector, id, PRICE, PRICE - 1));
        market.confirmCompletion(id);
        vm.clearMockedCalls();

        uint256 open = _open();
        vm.mockCall(address(escrow), abi.encodeCall(escrow.refund, (open)), abi.encode(PRICE + 1));
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IServiceMarketplace.EscrowAmountMismatch.selector, open, PRICE, PRICE + 1)
        );
        market.cancelRequest(open);
    }

    // ------------------------------------------------------------------
    // Reentrancy across marketplace + escrow
    // ------------------------------------------------------------------

    function test_Reentrancy_WithdrawHookCannotCancel() public {
        HookToken token = new HookToken();
        usdc = MockUSDC(address(token));
        _deploySystem(address(token));
        ReentrantBuyer rb = new ReentrantBuyer(market, IERC20(address(token)));
        token.mint(address(rb), 100e6);
        (uint64 a, uint64 s) = _deadlines();
        uint256 first = rb.create(a, s);
        uint256 second = rb.create(a, s);
        rb.cancel(first);
        token.setHooked(address(rb), true);
        rb.setMode(2, second);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rb.withdraw();
        assertEq(uint8(_status(second)), uint8(ClinovaTypes.Status.OPEN));
        assertEq(escrow.credit(address(rb)), 25e6);
    }
}
