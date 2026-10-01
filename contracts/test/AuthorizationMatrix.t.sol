// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClinovaBase} from "./ClinovaBase.sol";
import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";

/// @notice Phase 5 §16: authorization matrix. Every externally callable state-changing function of the five
///         contracts is called by each of 16 actors, from a state in which the call is otherwise valid (so a revert
///         can only come from authorization or ownership). The allowed set is written out explicitly per function
///         and compared exactly: an extra success or an extra failure both fail the test.
/// @dev Authorization is judged by protocol ownership, not only modifiers: e.g. withdraw() is "anyone" at the
///      modifier level but only the account that owns a credit can succeed.
contract AuthorizationMatrixTest is ClinovaBase {
    uint256 internal constant N = 16;
    address[N] internal actors;
    string[N] internal names;

    // actor indices
    uint256 internal constant BUYER = 0;
    uint256 internal constant BUYER2 = 1;
    uint256 internal constant ALICE = 2; // the assigned provider
    uint256 internal constant BOB = 3; // another eligible provider
    uint256 internal constant CAROL = 4; // registered, unverified provider
    uint256 internal constant VERIFIER = 5; // VERIFIER_ROLE on registry and marketplace
    uint256 internal constant REG_VERIFIER = 6; // VERIFIER_ROLE on registry only
    uint256 internal constant MKT_VERIFIER = 7; // VERIFIER_ROLE on marketplace only
    uint256 internal constant ADMIN = 8;
    uint256 internal constant PAUSER = 9;
    uint256 internal constant ATTACKER = 10;
    uint256 internal constant MARKET = 11;
    uint256 internal constant ESCROW = 12;
    uint256 internal constant POS = 13;
    uint256 internal constant REP = 14;
    uint256 internal constant REGISTRY = 15;

    uint256 internal constant ALL = (1 << N) - 1;
    uint256 internal constant CONTRACTS = (1 << MARKET) | (1 << ESCROW) | (1 << POS) | (1 << REP) | (1 << REGISTRY);
    uint256 internal constant EOAS = ALL & ~CONTRACTS;

    function setUp() public override {
        super.setUp();
        address regVerifier = makeAddr("registry-only-verifier");
        address mktVerifier = makeAddr("market-only-verifier");
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), regVerifier);
        market.grantRole(market.VERIFIER_ROLE(), mktVerifier);
        vm.stopPrank();
        actors = [
            buyer,
            buyer2,
            alice,
            bob,
            carol,
            verifier,
            regVerifier,
            mktVerifier,
            admin,
            pauser,
            attacker,
            address(market),
            address(escrow),
            address(pos),
            address(rep),
            address(registry)
        ];
        names = [
            "buyer",
            "buyer2",
            "alice",
            "bob",
            "carol",
            "verifier",
            "regVerifier",
            "mktVerifier",
            "admin",
            "pauser",
            "attacker",
            "market",
            "escrow",
            "pos",
            "rep",
            "registry"
        ];
        // Every EOA can afford and has approved a request, so createRequest is judged on authorization alone.
        for (uint256 i = 0; i < N; ++i) {
            if ((EOAS >> i) & 1 == 1) _fundBuyer(actors[i], 1_000e6);
        }
    }

    function _bit(uint256 i) internal pure returns (uint256) {
        return 1 << i;
    }

    /// @dev For each actor not in `skip`: snapshot, call, compare success with `allowed`, restore.
    function _check(string memory fn, address target, bytes memory data, uint256 allowed, uint256 skip) internal {
        for (uint256 i = 0; i < N; ++i) {
            if ((skip >> i) & 1 == 1) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(actors[i]);
            (bool ok,) = target.call(data);
            bool want = (allowed >> i) & 1 == 1;
            if (ok != want) {
                fail(string.concat(fn, ": ", names[i], want ? " should succeed" : " must not succeed"));
            }
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------
    // ServiceMarketplace
    // ------------------------------------------------------------------

    function test_Auth_Market_CreateRequest() public {
        (uint64 a, uint64 s) = _deadlines();
        _check(
            "createRequest",
            address(market),
            abi.encodeCall(market.createRequest, (address(0), CBC, REGION, PRICE, a, s)),
            EOAS,
            CONTRACTS
        );
    }

    function test_Auth_Market_BuyerFunctions() public {
        uint256 open = _open();
        _check("cancelRequest", address(market), abi.encodeCall(market.cancelRequest, (open)), _bit(BUYER), 0);
        uint256 comp = _completed(alice);
        _check("confirmCompletion", address(market), abi.encodeCall(market.confirmCompletion, (comp)), _bit(BUYER), 0);
        _check(
            "openDispute(COMPLETED)",
            address(market),
            abi.encodeCall(market.openDispute, (comp, REASON)),
            _bit(BUYER),
            0
        );
    }

    function test_Auth_Market_ProviderFunctions() public {
        uint256 open = _open();
        // Only eligible providers; never the buyer, verifiers, admin or contracts.
        _check(
            "acceptRequest", address(market), abi.encodeCall(market.acceptRequest, (open)), _bit(ALICE) | _bit(BOB), 0
        );
        uint256 directed = _create(buyer, bob, PRICE);
        _check(
            "acceptRequest(directed)", address(market), abi.encodeCall(market.acceptRequest, (directed)), _bit(BOB), 0
        );
        uint256 acc = _accepted(alice);
        _check("startService", address(market), abi.encodeCall(market.startService, (acc)), _bit(ALICE), 0);
        _check(
            "openDispute(ACCEPTED)",
            address(market),
            abi.encodeCall(market.openDispute, (acc, REASON)),
            _bit(BUYER) | _bit(ALICE),
            0
        );
        uint256 svc = _inService(alice);
        _check(
            "submitProof", address(market), abi.encodeCall(market.submitProof, (svc, keccak256("c"))), _bit(ALICE), 0
        );
    }

    function test_Auth_Market_VerifierFunctions() public {
        uint256 comp = _completed(alice);
        uint256 verifiers = _bit(VERIFIER) | _bit(MKT_VERIFIER); // registry-only verifier has no power here
        _check("approveProof", address(market), abi.encodeCall(market.approveProof, (comp)), verifiers, 0);
        _check("rejectProof", address(market), abi.encodeCall(market.rejectProof, (comp, REASON)), verifiers, 0);
        uint256 disp = _disputedFromCompleted(alice);
        for (uint8 res = 0; res < 3; ++res) {
            _check(
                "resolveDispute",
                address(market),
                abi.encodeCall(market.resolveDispute, (disp, ClinovaTypes.Resolution(res))),
                verifiers,
                0
            );
        }
    }

    /// The parties never review their own request, even when they hold VERIFIER_ROLE.
    function test_Auth_Market_PartiesWithVerifierRoleStillBlocked() public {
        bytes32 role = market.VERIFIER_ROLE();
        vm.startPrank(admin);
        market.grantRole(role, buyer);
        market.grantRole(role, alice);
        vm.stopPrank();
        uint256 comp = _completed(alice);
        uint256 verifiers = _bit(VERIFIER) | _bit(MKT_VERIFIER);
        _check("approveProof(party roles)", address(market), abi.encodeCall(market.approveProof, (comp)), verifiers, 0);
        uint256 disp = _disputedFromCompleted(alice);
        _check(
            "resolveDispute(party roles)",
            address(market),
            abi.encodeCall(market.resolveDispute, (disp, ClinovaTypes.Resolution.PROVIDER_WINS)),
            verifiers,
            0
        );
    }

    function test_Auth_Market_TimeGatedExits() public {
        uint256 open = _open();
        uint256 acc = _accepted(alice);
        uint256 comp = _completed(alice);
        uint256 disp = _disputedFromCompleted(alice);
        vm.warp(vm.getBlockTimestamp() + 60 days);
        _check("expireRequest(OPEN)", address(market), abi.encodeCall(market.expireRequest, (open)), ALL, 0);
        _check(
            "expireRequest(ACCEPTED)",
            address(market),
            abi.encodeCall(market.expireRequest, (acc)),
            _bit(BUYER) | _bit(ALICE),
            0
        );
        _check("closeUnreviewed", address(market), abi.encodeCall(market.closeUnreviewed, (comp)), ALL, 0);
        _check(
            "resolveDisputeByTimeout", address(market), abi.encodeCall(market.resolveDisputeByTimeout, (disp)), ALL, 0
        );
    }

    function test_Auth_Market_Admin() public {
        _check("setMinPrice", address(market), abi.encodeCall(market.setMinPrice, (2e6)), _bit(ADMIN), 0);
        _check("setReviewPeriod", address(market), abi.encodeCall(market.setReviewPeriod, (2 days)), _bit(ADMIN), 0);
        _check("setDisputePeriod", address(market), abi.encodeCall(market.setDisputePeriod, (5 days)), _bit(ADMIN), 0);
        bytes32 v = market.VERIFIER_ROLE();
        _check("grantRole", address(market), abi.encodeCall(market.grantRole, (v, attacker)), _bit(ADMIN), 0);
        _check("revokeRole", address(market), abi.encodeCall(market.revokeRole, (v, verifier)), _bit(ADMIN), 0);
        // Nobody, not even the admin, can grant DEFAULT_ADMIN_ROLE directly (2-step + delay only).
        bytes32 adm = market.DEFAULT_ADMIN_ROLE();
        _check("grantRole(admin)", address(market), abi.encodeCall(market.grantRole, (adm, attacker)), 0, 0);
        _check(
            "beginDefaultAdminTransfer",
            address(market),
            abi.encodeCall(market.beginDefaultAdminTransfer, (attacker)),
            _bit(ADMIN),
            0
        );
        _check("pause", address(market), abi.encodeCall(market.pause, ()), _bit(PAUSER), 0);
        vm.prank(pauser);
        market.pause();
        _check("unpause", address(market), abi.encodeCall(market.unpause, ()), _bit(PAUSER), 0);
    }

    // ------------------------------------------------------------------
    // ClinovaEscrow
    // ------------------------------------------------------------------

    function test_Auth_Escrow_ModuleWrites() public {
        uint256 id = 7_777;
        usdc.mint(address(escrow), 10e6);
        _check("lock", address(escrow), abi.encodeCall(escrow.lock, (id, buyer, 10e6)), _bit(MARKET), 0);
        vm.prank(address(market));
        escrow.lock(id, buyer, 10e6);
        _check("assignPayee", address(escrow), abi.encodeCall(escrow.assignPayee, (id, alice)), _bit(MARKET), 0);
        vm.prank(address(market));
        escrow.assignPayee(id, alice);
        _check("release", address(escrow), abi.encodeCall(escrow.release, (id)), _bit(MARKET), 0);
        _check("refund", address(escrow), abi.encodeCall(escrow.refund, (id)), _bit(MARKET), 0);
    }

    /// Withdrawal is "anyone" at the modifier level, but only the owner of a credit can take anything.
    function test_Auth_Escrow_WithdrawOwnCreditOnly() public {
        uint256 id = _open();
        vm.prank(buyer);
        market.cancelRequest(id);
        _check("withdraw", address(escrow), abi.encodeWithSignature("withdraw()"), _bit(BUYER), 0);
        _check("withdrawTo", address(escrow), abi.encodeCall(escrow.withdrawTo, (attacker)), _bit(BUYER), 0);
    }

    // ------------------------------------------------------------------
    // ProviderRegistry
    // ------------------------------------------------------------------

    function test_Auth_Registry_Verifier() public {
        uint256 regVerifiers = _bit(VERIFIER) | _bit(REG_VERIFIER); // marketplace-only verifier has no power here
        _check("verifyProvider", address(registry), abi.encodeCall(registry.verifyProvider, (carol)), regVerifiers, 0);
        _check(
            "revokeVerification",
            address(registry),
            abi.encodeCall(registry.revokeVerification, (alice)),
            regVerifiers,
            0
        );
    }

    function test_Auth_Registry_MarketplaceOnly() public {
        uint256 id = 6_666;
        _check(
            "recordJobAccepted",
            address(registry),
            abi.encodeCall(registry.recordJobAccepted, (id, alice, CBC)),
            _bit(MARKET),
            0
        );
        vm.prank(address(market));
        registry.recordJobAccepted(id, alice, CBC);
        _check(
            "recordJobClosed", address(registry), abi.encodeCall(registry.recordJobClosed, (id, alice)), _bit(MARKET), 0
        );
    }

    function test_Auth_Registry_AdminAndPauser() public {
        _check("setMinStake", address(registry), abi.encodeCall(registry.setMinStake, (50e6)), _bit(ADMIN), 0);
        _check(
            "setUnbondingPeriod",
            address(registry),
            abi.encodeCall(registry.setUnbondingPeriod, (2 days)),
            _bit(ADMIN),
            0
        );
        bytes32 v = registry.VERIFIER_ROLE();
        _check("grantRole", address(registry), abi.encodeCall(registry.grantRole, (v, attacker)), _bit(ADMIN), 0);
        _check("pause", address(registry), abi.encodeCall(registry.pause, ()), _bit(PAUSER), 0);
        vm.prank(pauser);
        registry.pause();
        _check("unpause", address(registry), abi.encodeCall(registry.unpause, ()), _bit(PAUSER), 0);
    }

    /// Provider self-functions act only on msg.sender's own record: nobody can act for another provider.
    function test_Auth_Registry_ProviderSelfOnly() public {
        uint256 registered = _bit(ALICE) | _bit(BOB) | _bit(CAROL);
        uint256 active = _bit(ALICE) | _bit(BOB);
        _check("requestUnstake", address(registry), abi.encodeCall(registry.requestUnstake, ()), registered, 0);
        _check("deactivate", address(registry), abi.encodeCall(registry.deactivate, ()), active, 0);
        _check(
            "updateProfile",
            address(registry),
            abi.encodeCall(registry.updateProfile, (keccak256("m2"), REGION)),
            registered,
            0
        );
        _check("addCapability", address(registry), abi.encodeCall(registry.addCapability, (GLUCOSE)), registered, 0);
        _check("removeCapability", address(registry), abi.encodeCall(registry.removeCapability, (CBC)), registered, 0);
        // Only alice is unbonded and ready: only alice can take a stake out, and only her own.
        vm.prank(alice);
        registry.requestUnstake();
        vm.warp(vm.getBlockTimestamp() + UNBONDING);
        _check("withdrawStake", address(registry), abi.encodeCall(registry.withdrawStake, ()), _bit(ALICE), 0);
    }

    // ------------------------------------------------------------------
    // ProofOfService and ReputationRegistry
    // ------------------------------------------------------------------

    function test_Auth_ProofOfService_MarketplaceOnly() public {
        uint256 svc = _inService(alice);
        _check("pos.submit", address(pos), abi.encodeCall(pos.submit, (svc, alice, keccak256("e"))), _bit(MARKET), 0);
        uint256 comp = _completed(alice);
        _check("pos.approve", address(pos), abi.encodeCall(pos.approve, (comp, verifier)), _bit(MARKET), 0);
        _check("pos.reject", address(pos), abi.encodeCall(pos.reject, (comp, verifier, REASON)), _bit(MARKET), 0);
        _check(
            "pos.markBuyerAccepted", address(pos), abi.encodeCall(pos.markBuyerAccepted, (comp, buyer)), _bit(MARKET), 0
        );
        _check("pos.markUnresolved", address(pos), abi.encodeCall(pos.markUnresolved, (comp)), _bit(MARKET), 0);
    }

    /// recordOutcome is never reachable in a recordable state outside the marketplace's own atomic transition, so the
    /// gate is shown directly: every non-marketplace caller fails with OnlyMarketplace, the marketplace gets past it.
    function test_Auth_Reputation_MarketplaceOnly() public {
        uint256 id = _completed(alice);
        vm.prank(buyer);
        market.confirmCompletion(id);
        for (uint256 i = 0; i < N; ++i) {
            vm.prank(actors[i]);
            if (i == MARKET) {
                vm.expectRevert(abi.encodeWithSelector(IReputationRegistry.OutcomeAlreadyRecorded.selector, id));
            } else {
                vm.expectRevert(IReputationRegistry.OnlyMarketplace.selector);
            }
            rep.recordOutcome(id, true);
        }
    }
}
