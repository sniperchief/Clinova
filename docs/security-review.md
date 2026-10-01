# Clinova Security Review Log

This is a living document. Phase 1 contains the design-level review. Phase 2 covers the ProviderRegistry code review. Phase 3 covers ServiceMarketplace and ClinovaEscrow. Phase 4 covers ProofOfService and ReputationRegistry. Phase 5 is the whole-protocol security, invariant and fork-testing pass before testnet deployment.

## Phase 1: design review (2026-09-30)

### Checks performed

| Check | Result |
|---|---|
| Contracts have no overlapping responsibilities | Pass. Each piece of state has exactly one owning contract and one writer (architecture §3). |
| State machine is internally consistent | Pass. Every non-terminal state has a defined exit. Terminal states are absorbing. Every transition names an actor, conditions and an event. No backwards transitions. `NONE = 0` guards nonexistent IDs. |
| Escrow cannot be moved by the admin | Pass (by design). No token-moving admin function, no upgrade proxy, and the marketplace hook is an immutable address, not a role. |
| Pause cannot freeze funds | Pass (by design). Only new-obligation entry points are pausable. |
| Privacy boundary | Pass (by design). No `string`/`bytes` in the external API. Commitments are salted. The onchain field list is enumerated. |
| Arbitrum-specific pitfalls | Pass. No `block.number`, no onchain randomness, hours-scale windows, O(1) operations. |
| OZ primitives appropriate | Pass. See the notes below. |
| Account-abstraction compatible | Pass (by design). No `tx.origin` and no EOA-only checks. |

### OpenZeppelin primitive notes

- **`AccessControlDefaultAdminRules`** is preferred over plain `AccessControl` because it gives a single admin and a delayed 2-step transfer. This reduces the admin-takeover risk.
- **`ReentrancyGuard`** is the standard storage-based guard. `ReentrancyGuardTransient` would also work on Arbitrum (Cancun). The storage variant is chosen for simplicity and broad tooling support. Gas is negligible on Arbitrum.
- **`SafeERC20`** is required because it tolerates tokens that do not return a boolean. USDC returns `bool`, but the wrapper is kept as defence in depth.
- **`Pausable`** is scoped to new-obligation functions only.
- **Not used:** `Ownable` (redundant with AccessControl), upgradeable proxies (no upgrade key in the MVP), `PullPayment`/`Escrow` utilities (removed from OZ 5.x; the pull-payment logic is written explicitly and minimally in `ClinovaEscrow`).

### Open issues (to resolve before or during Phase 2)

| ID | Issue | Recommendation |
|---|---|---|
| OI-1 | **DISPUTED depends on verifier liveness.** | **Resolved in Phase 3 (P3-1):** a dispute timeout gives a no-fault refund after a snapshotted `disputeDeadline`. The fairness residual is R3-1. |
| OI-2 | **The admin can grant itself `VERIFIER_ROLE`.** | Use a multisig admin. Optionally require a timelock on role grants (`AccessControlDefaultAdminRules` delays admin transfer only, not role grants). |
| OI-3 | **Single-verifier trust.** One verifier can approve a fraudulent proof. | Accept for the MVP and document it. Future: k-of-n verifier approvals or verifier staking. |
| OI-4 | **Provider key loss.** No ownership transfer, so stake is recoverable only by the same key. | Recommend smart-account wallets (recovery) for providers. Do not add an admin override. |
| OI-5 | **Circle USDC is upgradeable, pausable and has a blacklist.** | Accept. Pull payments limit the impact. Document it in the UI. |
| OI-6 | **Deploy wiring** uses a precomputed CREATE address. | **Resolved in Phase 3:** the marketplace constructor reverts on bad wiring, and integration tests deploy through `Deploy.s.sol`. |
| OI-7 | **Etherscan V2 key** for chain 421614 is unverified until the first deploy. | Confirm during the Phase 2 deployment. |
| OI-8 | **Metadata correlation privacy** (serviceType + region + time). | Keep regions coarse. The SDK should refuse fine-grained location input. |
| OI-9 | **Sybil self-dealing** (a buyer's second wallet acting as a provider). | Bounded by verification and stake. Accept for the MVP. |
| OI-10 | **Arbitrum Sepolia gas floor.** The docs table lists a 0.2 gwei floor, but a live `eth_gasPrice` returned ≈0.03 gwei. | Irrelevant to logic. Always use `eth_estimateGas`; never hardcode gas prices. |

## Phase 2: ProviderRegistry code review (2026-09-30)

**Scope:** `contracts/src/ProviderRegistry.sol` (non-upgradeable), `IProviderRegistry.sol`, and `ClinovaTypes.Provider`.

**Status:** implemented, tested and manually reviewed. **Not externally audited.** Passing tests show the properties below hold for the tested inputs and sequences. They do not prove the contract is secure.

### Issues found during Phase 2 and how they were handled

| ID | Found in | Issue | Resolution |
|---|---|---|---|
| P2-1 | Phase 1 spec | `register` required no stake, so unstaked providers could spam registrations and consume verifier effort | **Mitigated.** Registration requires `stakeAmount >= minStake`, pulled atomically. |
| P2-2 | Phase 1 spec | `setActive(true)` did not require verification (activation before verification) | **Mitigated.** `activate()` requires verified, `stake >= minStake`, and no pending unstake. Invariant-tested: active ⇒ verified. |
| P2-3 | Phase 1 spec | Capabilities could be added after verification, bypassing the verifier | **Mitigated.** `addCapability` revokes verification. `removeCapability` does not. |
| P2-4 | Phase 1 spec | The marketplace's `incrementActiveJobs` trusted the marketplace completely | **Mitigated.** `recordJobAccepted` re-checks full eligibility in the registry. |
| P2-5 | Phase 1 spec | `updateProfile` cleared `verified` but left `active`, an inconsistent state | **Mitigated.** Any revocation also deactivates. |
| P2-6 | `forge lint` | `transferFrom` with an arbitrary `from` (the value was always `msg.sender`, but only by convention) | **Mitigated.** `_depositStake` pulls from `msg.sender` directly. |
| P2-7 | `forge lint` | Unchecked `uint64(block.timestamp)` cast | **Mitigated.** Uses `SafeCast.toUint64`. |
| P2-8 | `forge lint` | `nonReentrant` was not the first modifier | **Mitigated.** Reordered on `register` and `depositStake`. |
| P2-9 | Test review | The first invariant handler hardly reached deep paths. No withdraw or job-close ever succeeded, so some invariants passed **vacuously**. | **Mitigated.** The handler now prefers actors that can succeed, `withdraw` can warp to unbonding, and `test_HandlerReachesDeepPaths` asserts that each deep path succeeds. |
| P2-10 | Test review | The handler's seed arithmetic overflowed for large fuzz seeds (134 discarded calls) | **Mitigated.** Seeds are reduced modulo before addition. The campaign now shows 0 handler reverts. |

**Lint findings accepted after triage:**

- `missing-events-arithmetic` (`unbondingPeriod`) and `missing-events-access-control` (`_offersService`) are false positives: both paths emit (`ParameterUpdated`, `ProviderCapabilityRemoved`).
- `require-revert-in-loop` in `register` is intentional: an invalid or duplicate capability must revert the whole registration.
- `block-timestamp` is suppressed with a justification: unbonding is day-scale, and Arbitrum timestamp skew is in hours.

### Manual review questions

| # | Question | Answer (what enforces it) |
|---|---|---|
| 1 | Can anyone steal provider stake? | **No path found.** The only outbound transfer is in `withdrawStake`, which pays `msg.sender` its own `stake`. It has no recipient or amount parameter. Tested for attacker, admin (holding every role), verifier, marketplace and pauser, plus fuzz and invariant coverage. |
| 2 | Can anyone impersonate a provider? | **No.** Every provider function keys on `msg.sender`. No function takes a provider address except verifier and marketplace functions, and those cannot touch stake or profile data. There is no ownership transfer. |
| 3 | Can an unverified provider become eligible? | **No path found.** Eligibility requires `verified`, which only `verifyProvider` sets. Invariant: the `verified` flag equals the ghost model driven only by verifier actions. |
| 4 | Can a provider withdraw more than deposited? | **No.** Withdrawal is exactly the recorded stake, zeroed before transfer. Invariants: per-provider stake equals deposited minus withdrawn, withdrawn ≤ deposited, and wallet balances match own flows. |
| 5 | Can the marketplace gain excessive authority? | **Limited to the job counter.** It can only increment (for a currently eligible provider) or decrement `activeJobs`. The address is immutable and cannot be granted. **Residual:** see R-1 and R-2. |
| 6 | Can the admin move provider funds? | **No function exists.** The admin can grant roles (including verifier, see OI-2), set bounded parameters, and do nothing else. |
| 7 | Can provider state become inconsistent? | **Invariant-tested:** active ⇒ registered && verified && not unbonding; unregistered ⇒ unverified and zero stake. Known acceptable state: an active provider whose stake falls below a *raised* `minStake` is not eligible until it tops up (tested). |
| 8 | Can pause permanently lock funds? | **No.** Only `register` and `depositStake` are pausable. Withdrawal and job-close under pause are tested. |
| 9 | Can token transfer failures corrupt accounting? | **No.** Transfers go through `SafeERC20`, and a failed transfer reverts the whole transaction. Tested with a token that returns `false`, fee-on-transfer (`TransferAmountMismatch`), insufficient balance or allowance, and a `uint128` overflow. |
| 10 | Can capability data leak sensitive info? | **Not by the contract.** Capabilities are `bytes32` catalog codes. There are no `string` or `bytes` inputs. A provider could hash something private into its *own* profile fields, but that is the provider's own data and is covered by SDK guidance (Phase 3). |

### Protections implemented

- `AccessControlDefaultAdminRules`: single admin with a delayed 2-step transfer (tested).
- Roles: `VERIFIER_ROLE` and `PAUSER_ROLE`. `PAUSER_ROLE` is kept separate so a fast operational key can pause without being admin, and pause is harmless by design.
- Marketplace authority is an immutable address. `register` rejects the marketplace.
- `ReentrancyGuard` on the three token-moving functions. The token is injected, so hook-style tokens are defended against. Tested with an ERC777-style hook token re-entering both `withdrawStake` and `depositStake`.
- Checks-effects-interactions everywhere. The deposit balance-delta check runs after the transfer, and any mismatch reverts the whole transaction.
- `SafeERC20` and `SafeCast`. USDC `decimals() == 6` is checked at construction.
- Bounded admin parameters. Unbonding is snapshotted per request.
- Custom errors only. There are no `string` or `bytes` parameters.

### Test coverage

| Suite | Tests | Notes |
|---|---|---|
| `ProviderRegistry.t.sol` (unit) | 95 | Constructor, registration, profile, verification, capabilities, activation, staking, token failure modes, reentrancy, marketplace scope, admin/roles, pause scope |
| `ProviderRegistry.fuzz.t.sol` | 10 × 1,000 runs | Stake amounts, provider addresses, hashes, capability IDs, deposit/withdraw cycles, own-stake-only withdrawal, non-verifier/non-marketplace callers, unbonding boundary |
| `ProviderRegistry.invariant.t.sol` | 11 invariants (256 runs × 64 depth) + 1 handler smoke test | Handler: 17 actions across providers, verifier, marketplace, admin, pauser and attacker |
| `forge coverage` (src) | 100% lines, statements, branches and functions for `ProviderRegistry.sol` | Coverage shows reachability, not correctness |

**Invariants tested:**

1. Token custody equals `totalStaked`.
2. `totalStaked` equals the sum of stakes.
3. Per-provider stake equals deposited minus withdrawn, and withdrawn ≤ deposited.
4. Wallet balances match each provider's own flows (no cross-provider leakage).
5. Privileged and attacker addresses hold no funds.
6. Provider uniqueness.
7. `verified` changes only via verifier actions or self-revocation.
8. Active implies verified and not unbonding.
9. Eligibility requires every condition.
10. `activeJobs` matches marketplace records.
11. No unauthorized call ever succeeds.

**Known coverage gap:** the full seven-step chain (accept → close → unstake → withdraw) is rarely produced by the random campaign within 64 calls. It is covered deterministically by unit tests and `test_HandlerReachesDeepPaths`.

### Remaining risks (registry)

| ID | Risk | Status |
|---|---|---|
| R-1 | **Stake liveness depends on the marketplace.** If the marketplace never calls `recordJobClosed` (for example because of a bug), the provider's stake stays locked. Nothing is stolen, but it is stuck. | **Resolved in Phase 3 (P3-3, P3-5).** The marketplace closes the job on every terminal transition, the provider can expire a missed-deadline job, and the invariant-tested `activeJobs` matches the lifecycle. |
| R-2 | **Provider consent to jobs is not checked by the registry.** A buggy marketplace could record jobs against an eligible provider that never accepted them, blocking withdrawal. | **Resolved in Phase 3 (P3-5).** Acceptance binds `msg.sender`, and the registry binds `requestId → provider` once. |
| R-3 | Two colluding verifiers can verify each other's provider wallets. Self-verification is blocked only for the same address. | Accepted for the MVP (OI-3). |
| R-4 | The admin can grant itself `VERIFIER_ROLE`. | Accepted (OI-2). Use a multisig admin. |
| R-5 | Provider key loss makes the stake unrecoverable. There is no transfer or admin override, by design. | Accepted (OI-4). Recommend smart-account wallets. |
| R-6 | Tokens sent directly to the registry are unrecoverable. There is no rescue function, by design. | Accepted. This does not affect accounting, because custody ≥ `totalStaked`. |
| R-7 | Circle USDC pause or blacklist could block a specific provider's deposit or withdrawal. | Accepted (OI-5). It only affects that provider. |
| R-8 | Not yet tested against real Arbitrum Sepolia USDC in a fork integration test of the registry. The Phase 1 fork test only checks token metadata. | **Not yet verified.** Planned with the Phase 3 deploy script. |
| R-9 | No external audit and no third-party static analysis. Slither and Aderyn are not installed. Only `forge lint` was used. | **Not yet verified.** |

## Phase 3: ServiceMarketplace + ClinovaEscrow code review (2026-09-30)

**Scope:**

- `ServiceMarketplace.sol` and `ClinovaEscrow.sol` (both new);
- the `ProviderRegistry.sol` job-binding change;
- `script/Deploy.s.sol`.

All contracts are non-upgradeable.

**Status:** implemented, tested and manually reviewed. **Not externally audited. No third-party static analysis** (Slither and Aderyn are not installed; only `forge lint` was run). Passing tests show the listed properties hold for the tested inputs and sequences. They do not prove the contracts are secure.

### Issues found in Phase 3 and how they were handled

| ID | Found in | Issue | Resolution |
|---|---|---|---|
| P3-1 | Phase 1 spec (OI-1) | DISPUTED could stay locked forever without a verifier | **Fixed.** `resolveDisputeByTimeout` after a snapshotted `disputeDeadline` returns funds to the payer. It is recorded as unresolved (`DisputeTimedOut`), not as a fault finding. Verifiers may still resolve late, until the timeout executes. |
| P3-2 | Phase 1 spec | COMPLETED could stay locked forever if the buyer never confirms and no verifier acts. The Phase 1 invariant I12 wrongly claimed buyer confirmation was sufficient. | **Fixed.** `finalizeSettlement` after an undisputed review window pays the provider. |
| P3-3 | Phase 1 spec | Only the buyer could expire a missed-deadline job. A vanished buyer would lock the provider's `activeJobs`, and so its stake, forever. | **Fixed.** The assigned provider may also expire. The refund still goes only to the buyer. |
| P3-4 | Phase 1 spec | Disputes had no deadline, so a party could dispute after a deterministic deadline to stall expiry or finalization | **Fixed.** Disputes are only allowed before `serviceDeadline`, or within the review window. The provider cannot dispute its own completed job. |
| P3-5 | Phase 2 R-1/R-2 | The registry trusted the marketplace to close the *right* provider's job | **Fixed.** The registry binds `requestId → provider` once, and rejects mismatched closes, double closes and re-binding. |
| P3-6 | Manual review | **Proof-hash squatting.** Global replay protection let another provider burn someone else's commitment first. | **Fixed.** Replay protection is scoped per provider. Tested. |
| P3-7 | Design | The escrow initially would have pulled tokens from a `payer` argument (arbitrary `from`) | **Avoided.** Buyers approve the marketplace. It pulls only from `msg.sender` into the escrow. The escrow verifies the tokens arrived (`surplus >= amount`) rather than trusting `amount`. |
| P3-8 | Design | The escrow could be told to pay any address at settlement | **Avoided.** The payee is bound once at acceptance. `release(id)` takes no recipient. |
| P3-9 | `forge lint` | `reentrancy-events`: lifecycle events were emitted after module calls (6 sites) | **Fixed.** Events are emitted before external calls, and amounts use `request.price`. |
| P3-10 | `forge lint` | `unused-return` on the escrow's release/refund amounts | **Fixed.** The marketplace checks that the escrow moved exactly `price` (`EscrowAmountMismatch`). Tested via `vm.mockCall`. |
| P3-11 | Test review | Test-side bugs: the handler smoke test warped past all deadlines; `vm.prank` was consumed by a view call in `expectRevert` arguments (2 places) | **Fixed.** Found because the smoke test asserts that each path succeeds. |
| P3-12 | Coverage | Two constructor branches showed as uncovered despite tests | Root cause: forge coverage misattributes several reverting `new` calls inside one test. **Split into separate tests; coverage now attributes correctly.** |

**Lint findings remaining (from Phase 2, triaged):** two false-positive `missing-events-*` findings, and `require-revert-in-loop` in `register`, which is intentional.

### Manual review questions

| # | Question | Answer (what enforces it) |
|---|---|---|
| 1 | Can anyone steal escrow? | **No path found.** Outflows are `withdraw`/`withdrawTo` of the caller's own credit only. Credits come only from `release` (to the bound payee) or `refund` (to the recorded payer). Invariants: credit ownership and global conservation. |
| 2 | Can a buyer settle someone else's job? | No. `confirmCompletion` requires `msg.sender == request.buyer`. Settlement pays the bound provider regardless of who triggers it. |
| 3 | Can a provider claim another provider's job? | No. Acceptance binds `msg.sender`, directed requests are enforced, and start/proof require the assigned provider. Payee and registry bindings are set once. |
| 4 | Can the marketplace arbitrarily move escrow? | No. It can only lock (tokens must be present), bind a payee once, and release or refund a FUNDED deposit. No amount or recipient parameters exist for payouts. |
| 5 | Can the admin withdraw escrow? | No. The escrow has no admin and no rescue. Tested with an admin holding every role. |
| 6 | Can the admin modify an existing request's price? | No. There is no setter, and parameters are snapshotted (tested). |
| 7 | Can a request be funded twice? | No. Funding is atomic with creation, and escrow `lock` only works from NONE (tested directly). |
| 8–11 | Settle twice / refund twice / refund after settle / settle after refund? | No. The escrow's own terminal states are enforced independently of the marketplace (unit tests, plus the status⇔escrow invariant). |
| 12 | Can a provider withdraw stake while it has active jobs? | No. `ActiveObligation` in the registry (integration-tested). |
| 13 | Can `activeJobs` become inconsistent? | Invariant: `activeJobs` equals the lifecycle count for every provider after every call. The registry cannot underflow, because it closes only OPEN bound jobs. |
| 14 | Can a deadline be bypassed? | Boundary tests at `deadline`, `deadline + 1`, and fuzzed elapsed times. Actions use `now <= d` and exits use `now > d`. |
| 15 | Can dispute funds be permanently locked? | No. `resolveDisputeByTimeout` works with no verifier and while paused (unit + invariant). |
| 16 | Can pause permanently freeze funds? | No. Only create and accept are pausable, and the escrow has no pause. The liveness invariant runs while paused. |
| 17 | Can a malicious ERC20 break accounting? | The token is fixed and USDC-only. Tested: false-returning token, fee-on-transfer, hook/reentrant token, insufficient balance or allowance. The escrow fails closed if the balance ever falls below its obligations. |
| 18 | Can reentrancy break withdrawal or settlement? | `nonReentrant` on `createRequest` and on all escrow mutators and withdrawals (shared guard). Credit is zeroed before transfer. Tested with hook tokens. |
| 19 | Can arbitrary addresses impersonate providers? | No. Identity is always `msg.sender`. Fuzzed with arbitrary addresses. |
| 20 | Can the marketplace call the registry in a way that bypasses provider identity? | The marketplace only passes `msg.sender` (accept) or `request.provider` (close). The registry independently enforces eligibility and the per-request binding. |
| 21 | Can any admin role extract user funds? | No direct path. **Residual:** the admin can grant itself `VERIFIER_ROLE` and then settle disputes or approve completions, but only to the request's own bound provider or buyer (R-4). |
| 22 | Can a malicious sequence of valid calls violate accounting? | Not found. There are 9 invariants over 16,384 random calls, attacker actions included, plus a 1,000-run random-sequence fuzz with full checks after every step. |

### Test coverage (Phase 3 totals, whole repository)

| Suite | Tests | Notes |
|---|---|---|
| `ProviderRegistry.t.sol` | 98 | +3 for per-request job binding |
| `ProviderRegistry.fuzz.t.sol` | 10 × 1,000 runs | |
| `ProviderRegistry.invariant.t.sol` | 11 invariants + smoke | 256 × 64 |
| `ClinovaEscrow.t.sol` | 34 | Escrow in isolation (the test contract plays the marketplace) |
| `ServiceMarketplace.t.sol` | 79 | Creation, funding, acceptance, start/proof, cancel, expiry, settlement, disputes, timeout, pause matrix, admin, reentrancy |
| `Integration.t.sol` | 9 | Deploy script wiring, full provider lifecycle, expiry → stake exit, invalid registry scenarios, custody separation |
| `Clinova.fuzz.t.sol` | 7 × 1,000 runs | Prices, deadlines, IDs, callers, expiry timing, all 11 terminal paths, random call sequences |
| `Clinova.invariant.t.sol` | 9 invariants + smoke | 256 × 64 = 16,384 calls, **0 handler reverts** |
| `Foundation.t.sol` | 2 (+1 fork, skipped without RPC) | |
| **Total** | **243 passed, 0 failed, 1 skipped** | |
| `forge coverage` (src) | **100%** lines, statements, branches and functions for all three contracts | Coverage shows reachability, not correctness |

**Invariant depth was verified, not assumed.** Deliberately failing "probe" invariants showed that the random campaign itself reaches:

- accept, proof, confirm, approve, reject, dispute, resolve, timeout, finalize, expire, cancel and withdraw.

`test_HandlerReachesEveryPath` also asserts that each path succeeds deterministically.

**Phase 3 invariants:**

1. Exact escrow balance (locked + credited + donations).
2. Locked equals open obligations, and deposit equals price.
3. Credit plus withdrawn equals outcomes, per account; non-parties hold none.
4. Global USDC conservation; the marketplace holds none.
5. Status agrees with escrow state (never both settled and refunded).
6. Single provider and bound payee.
7. `activeJobs` matches the lifecycle, including registry job status.
8. No terminal change, no provider change, no unauthorized success.
9. **No permanent lock:** with the marketplace paused, all verifiers revoked and no admin action, every reachable state drains to terminal and all credits withdraw.

### Remaining risks (Phase 3)

| ID | Risk | Status |
|---|---|---|
| R3-1 | **Dispute fairness depends on verifier liveness.** If no verifier resolves within `disputePeriod`, the timeout refunds the buyer, even if the provider performed the service. A buyer could exploit a period of verifier absence with frivolous disputes. | **Known limitation.** Funds are never locked. Mitigations: 14-day default window, verifier SLAs, multiple verifiers; Phase 4 reputation can track per-buyer dispute rates. |
| R3-2 | **No slashing for acceptance hoarding.** A provider can accept and not serve, locking the buyer's funds until the buyer-chosen deadline. | **Known limitation.** Bounded by the buyer's own deadlines. The failure is visible on-chain. Slashing is out of scope. |
| R3-3 | **Optimistic finalization.** If the buyer is inattentive and no verifier rejects within the review window (at least 1 day, 3 by default), a fake completion gets paid. | **Resolved in Phase 4 (P4-1).** `finalizeSettlement` was removed; an unreviewed completion is refunded, never paid. |
| R3-4 | The Phase 3 completion commitment lives in the marketplace (`proofHashOf`). Phase 4 must move it to `ProofOfService` without changing the request model. | **Resolved in Phase 4.** Proofs live in `ProofOfService`, and `proofHashOf` was removed from the marketplace. |
| R3-5 | Not yet deployed or exercised on Arbitrum Sepolia with real Circle USDC. There is no fork integration test of the full flow. | **Not yet verified.** |
| R3-6 | No external audit and no Slither/Aderyn run | **Not yet verified.** |
| R-2..R-9 | Phase 2 registry risks (verifier collusion, admin self-grant of `VERIFIER_ROLE`, key loss, donations, USDC blacklist) | Unchanged. R-1/R-2 are addressed by P3-5. |

**Deployment note:** the production `admin` for all contracts must be a multisig. `VERIFIER_ROLE` must be granted separately on the registry and on the marketplace.

## Phase 4: ProofOfService + ReputationRegistry code review (2026-09-30)

**Scope:**

- `ProofOfService.sol` and `ReputationRegistry.sol` (both new);
- the proof and reputation integration in `ServiceMarketplace.sol`;
- `ClinovaTypes.sol` and the interfaces;
- `script/Deploy.s.sol`, which now deploys five contracts.

All contracts are non-upgradeable.

**Status:** implemented, tested and manually reviewed. **Not externally audited. Not deployed. Slither and Aderyn are not installed**, so only `forge lint` was run. Passing tests show the listed properties hold for the tested inputs and sequences. They do not prove the system is secure.

**Security statement:** Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion. The blockchain does not prove that a medical service happened.

### Issues found in Phase 4 and how they were handled

| ID | Found in | Issue | Resolution |
|---|---|---|---|
| P4-1 | Phase 3 R3-3 | An unchallenged fake completion was paid after the review window (`finalizeSettlement`) | **Fixed.** Payment now requires positive acceptance. `closeUnreviewed` refunds an unreviewed completion as no-fault, and liveness is preserved (invariant-tested). |
| P4-2 | Phase 1 proof-hash spec | The request/provider binding of the proof hash relied on an offchain convention | **Fixed.** `proofHash` is computed onchain from `(domain, chainId, PoS address, requestId, provider, evidenceCommitment)`. |
| P4-3 | Phase 3 design | `resolveDispute(PROVIDER_WINS)` after a verifier rejection would have paid on a rejected proof | **Fixed.** `REJECTED` is final, and `PROVIDER_WINS` requires `SUBMITTED` (`ProofNotApprovable`). |
| P4-4 | Design | A module callback into the marketplace (for example "PoS notifies approval") would give PoS settlement power | **Avoided.** The marketplace is the single entry point and calls PoS. PoS and reputation have **no** permission on any module. |
| P4-5 | Design | Reputation functions taking a caller-supplied provider (`recordSuccess(provider)`, as in the Phase 1 interface) | **Replaced.** `recordOutcome(requestId, fault)` derives the provider from the registry's acceptance binding and the facts from marketplace, registry and PoS state. It validates the fault flag against the status and records once per request. |
| P4-6 | Design | Admin, verifier or a buyer holding `VERIFIER_ROLE` reviewing its own request | Two layers: marketplace `ConflictOfInterest`, plus PoS `ConflictOfInterest` / `NotVerifier`. Attack-tested in the invariant suite with a buyer and a provider that both hold the role. |
| P4-7 | `forge lint` | `reentrancy-events` (3): marketplace events were emitted after the PoS calls | **Fixed.** Marketplace effects and events come first, and module calls last (all atomic). |
| P4-8 | `forge lint` | `unsafe-typecast` (2) in PoS; `uninitialized-local` in `submitProof` | **Fixed.** `SafeCast` and explicit initialization. |
| P4-9 | Review | The expired-after-acceptance counting rule documented a case (proof present) that cannot occur | Doc corrected: expiry is only possible before a proof exists. |

**Lint findings remaining** (Phase 2, previously triaged): 2 `missing-events-*` false positives, and 2 `require-revert-in-loop` in `ProviderRegistry.register`, which is intentional.

### Manual review questions

| # | Question | Answer (what enforces it) |
|---|---|---|
| 1 | Can Provider A submit proof for Provider B? | No. The marketplace allows only `msg.sender == request.provider`, and PoS independently requires `provider == request.provider`. Tested directly against the module. |
| 2 | Can the same proof be replayed for another request? | No. The bound `proofHash` differs per request, and `(provider, commitment)` is single-use. The fuzz suite replays constantly. |
| 3 | Can a verifier approve an unrelated proof? | A verifier can only act on a COMPLETED request by ID. The action touches only that request's proof, and PoS re-checks independence for that exact request. |
| 4 | Can a buyer or provider act as verifier? | No. Two independent checks; unit and invariant attack-tested. |
| 5 | Can approval bypass marketplace state? | No. PoS writes only on marketplace calls, and the marketplace checks its own state first. PoS cannot call the marketplace. |
| 6 | Can a rejected proof still cause payment? | No. `REJECTED` is final and `PROVIDER_WINS` requires `SUBMITTED`. Invariant: SETTLED ⇔ APPROVED/BUYER_ACCEPTED. |
| 7 | Can a proof be approved twice? | No. SUBMITTED → APPROVED once; PoS then reverts `ProofNotReviewable`. |
| 8 | Can reputation be counted twice? | No. `outcomeRecorded` per request. Invariant: one outcome per finished accepted job. |
| 9 | Can the marketplace assign reputation to the wrong provider? | No. The provider comes from the registry binding and is cross-checked. Invariant against an independent record. |
| 10 | Can the admin rewrite reputation history? | No. Neither module has an admin or setters. |
| 11 | Can arbitrary users call reputation functions? | No (`OnlyMarketplace`); attack-tested. |
| 12–13 | Can PoS or ReputationRegistry move USDC? | No. They have no token functions and hold no balance (tested). |
| 14 | Can proof submission create a permanent escrow lock? | No. COMPLETED always has `closeUnreviewed`, and DISPUTED has the timeout. `invariant_NoPermanentLock` drains every state while paused with no verifier. |
| 15 | Can disputes and proof review interact incorrectly? | Every combination is covered by the path-matrix integration test and the proof/request agreement invariant, including proof into dispute, reject → timeout, and buyer dispute → timeout (UNRESOLVED). |
| 16 | Can a malicious call sequence cause inconsistent cross-module state? | Not found. There are 13 system invariants over 16,384 random calls, including attacks on PoS and reputation, plus a 1,000-run random-sequence fuzz with cross-module checks after every step. |

### Test coverage (whole repository)

| Suite | Tests |
|---|---|
| `ProviderRegistry.t.sol` / `.fuzz` / `.invariant` | 98 / 10 × 1,000 runs / 11 invariants + smoke |
| `ClinovaEscrow.t.sol` | 34 |
| `ServiceMarketplace.t.sol` | 87 (+8: constructor wiring for 5 modules, unreviewed-close semantics, rejected-proof finality) |
| **`ProofOfService.t.sol`** (new) | **23** |
| **`ReputationRegistry.t.sol`** (new) | **21** |
| `Integration.t.sol` | 13 (+4: full proof → approve → settle → reputation flow, rejected proof, dispute resolutions, **path matrix**) |
| `Clinova.fuzz.t.sol` | 7 × 1,000 runs (terminal-path fuzz now also checks proof and reputation; random sequences replay commitments) |
| `Clinova.invariant.t.sol` | **13 invariants** (+4 proof/reputation) + smoke; 256 × 64 = 16,384 calls, 0 handler reverts |
| `Foundation.t.sol` | 2 + 1 skipped (fork test without RPC) |
| **Total** | **299 passed, 0 failed, 1 skipped** |
| `forge coverage` (src) | **100%** lines, statements, branches and functions for all five contracts |

**Non-vacuity was checked.** Deliberately failing probe invariants confirmed that the random campaign reaches:

- proof submission and proof into dispute;
- approve, reject and buyer confirm;
- dispute, and each of the three resolutions;
- timeout, unreviewed close, expiry and withdrawal;
- non-zero values of **all four** reputation counters.

`test_HandlerReachesEveryPath` also asserts each path deterministically.

### Remaining risks (Phase 4)

| ID | Risk | Status |
|---|---|---|
| R4-1 | **An honest provider can go unpaid if nobody reviews.** If the buyer doesn't confirm and no verifier approves before `reviewDeadline`, the completion is refunded (no fault recorded). This is the deliberate cost of fixing R3-3. | **Known trade-off.** Verifier SLAs must be shorter than `reviewPeriod` (default 7 days, maximum 14). Multiple verifiers recommended. |
| R4-2 | **Verifier trust.** A single verifier can approve a fake completion or reject a genuine one, within the conflict-of-interest rules. | Trust assumption (OI-3). Future: k-of-n approvals or verifier staking. |
| R4-3 | **The fault flag on a verifier refund is supplied by the marketplace** (from the verifier's `Resolution`). It cannot be derived onchain. | Validated against the status. A wrong flag needs a malicious verifier (R4-2). |
| R4-4 | **Evidence authenticity and storage are offchain.** The commitment proves integrity and timing, not truth. | Out of chain scope; handled in the verification service phase. |
| R4-5 | `disputes` is a neutral involvement count, and could be misread as negative by consumers | Documented in spec §9 |
| R3-1, R3-2, R-2..R-9 | Earlier risks (dispute fairness when verifiers are absent, no slashing for hoarding, admin can self-grant `VERIFIER_ROLE`, key loss, USDC issuer) | Unchanged |
| — | Not deployed; no fork test of the full flow against real Sepolia USDC; no external audit; no Slither/Aderyn | **Not yet verified** |

## Phase 5: whole-protocol security, fuzzing, invariants and fork testing (2026-10-01)

**Scope:** all five contracts, their interfaces and `ClinovaTypes`, `script/Deploy.s.sol`, the test suites, configuration and documentation. The protocol design was frozen: no features were added and no Phase 4 decision was reversed.

**Status:** reviewed, tested and statically analysed. **Not externally audited. Not deployed.** Passing tests show the properties below hold for the tested inputs and sequences. They do not prove the system is secure.

**Security statement.** Clinova does **not** claim fully trustless medical evidence verification. Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion.

### Baseline (before any Phase 5 change)

| Check | Result |
|---|---|
| `forge fmt --check` | pass |
| `forge build` | pass (lint notes only) |
| `forge test` | 299 passed, 0 failed, 1 skipped (fork check without RPC) |
| `forge coverage` (src) | 100% lines (539/539), statements (664/664), branches (119/119), functions (99/99) |
| `forge lint` | 4 warnings, all previously triaged (2 `missing-events-*` false positives, 2 intentional `require-revert-in-loop`) |

### Findings

No critical, high or medium severity vulnerability was found in the contracts. Each finding below was reproduced first (a failing test, or a demonstrated wrong value), then fixed or documented, then re-tested with the whole suite.

| ID | Severity | Issue | Root cause | Fix | Regression test |
|---|---|---|---|---|---|
| P5-1 | Low | `escrow.withdrawTo(address(escrow))` (or the marketplace address) succeeded: the caller's credit was zeroed and the tokens became unaccounted surplus (escrow) or stranded (marketplace) forever. Self-inflicted, but a permanent loss with no recovery path. | Recipient validation rejected only `address(0)`. | `withdrawTo` reverts `InvalidRecipient` for the escrow and the marketplace. Other contracts (registry, PoS, reputation) are unknown to the escrow and are documented instead. No other contract has a recipient parameter (`withdrawStake` always pays `msg.sender`). | `MaliciousTokenTest.test_WithdrawTo_RejectsEscrowAndMarketplaceAsRecipient` (failed before the fix); authorization matrix |
| P5-2 | Low (deployment) | `Deploy.s.sol` cast env values with unchecked `uint48`/`uint64`/`uint32` truncation. A mistyped value such as `REVIEW_PERIOD=4295572096` silently became 7 days and passed the contract bounds, deploying parameters the operator did not intend. | Unchecked downcasts. | `SafeCast` for every narrowed env value. | `DeployScriptTest.test_Run_EnvParsingAndDeploy` |
| P5-3 | Low (deployment hardening) | The script did not verify the deployment it produced: token address vs chain, admin and delay, leftover roles, parameters and most cross-references were unchecked (the marketplace constructor covers wiring only). | No post-deployment assertions. | `Deploy.verify()` runs at the end of every deployment, including every test fixture: non-zero code, all eight references, the same token everywhere with 6 decimals, **Circle USDC on chain 421614**, admin and delay, the deployer holds no admin, no operational role pre-granted, parameters, fresh unpaused state. | `DeployScriptTest` (8 tests, including swapped modules, a pre-granted role and a wrong token on 421614) |
| P5-4 | Informational (docs) | Documentation contradicted the Phase 4 code: `threat-model.md` and `architecture.md` (trust assumption 3) still said an unreviewed completion *settles to the provider*; the threat model referenced the removed `proofHashUsed`; the architecture deployment section described a 3-contract nonce layout. | Docs not updated with the Phase 4 change. | Corrected, and marked as corrected. | n/a |
| P5-5 | Informational | Onchain replay protection for raw evidence commitments is per deployment (R5-3). The `proofHash` is bound to chain, deployment, request and provider, but the same raw commitment could be submitted on another deployment or chain. | `evidenceCommitment` does not contain the request; binding it would need the preimage onchain. | Spec §5 now requires an evidence manifest (chain, PoS address, request, provider) that the verifier checks. No contract change. | `BoundariesAndReplayTest.test_Replay_AcrossDeployments` |

**Test-harness issues found and fixed during Phase 5.** These are not protocol bugs. They are recorded because each would have produced false confidence:

- The first version of the whole-protocol handler reached acceptance in about 1 of 48 attempts. Lifecycle churn made every provider ineligible, OPEN requests expired under random time jumps, and `cancel` always succeeded, so invariants passed vacuously. Fixed with targeted restorative actions, time-aware request selection and gating. The metrics table now shows every action succeeding (below).
- During mutation testing, Forge's build cache did not notice `sed -i` edits on this Windows machine ("No files changed, compilation skipped"), so mutants were silently not compiled. Re-run with `forge build --force`: every mutant was caught (below).
- One handler attack (a wrong provider calling `expireRequest`) was a false alarm on OPEN requests, where expiry is permissionless by design (T4). It is now restricted to ACCEPTED/IN_SERVICE requests.

### Cross-contract results

| Area | Result |
|---|---|
| Escrow | No issue. Σ funded == Σ released + Σ refunded + locked. Escrow transitions observed monotone after every call. Releases only to the accepting provider; no double payment. P5-1 fixed. |
| Provider stake | No issue. Registry balance == `totalStaked` + donations. Per-provider stake == deposited − withdrawn. Stake never left while the *marketplace* showed an open job (checked at every successful withdrawal). |
| Marketplace | No issue. All 240 (state × action) pairs match the spec table. |
| Proof | No issue. Final states are immutable even for direct marketplace calls; rejected proofs never pay; proof provider == accepting provider; replay blocked per provider. Documentation requirement P5-5. |
| Reputation | No issue in code. One outcome per closed job; counters equal an independent model; success ⇔ actual payment to that provider. Documented trade-off R5-2. |
| Authorization | No issue. 16 actors × every mutating function: only the expected set succeeds. Parties holding `VERIFIER_ROLE` still cannot review their own requests (checked twice). |
| Pause | No issue. Every stage tested with both contracts paused; only new obligations are blocked. |
| Disputes | No issue in code. Verifier liveness affects fairness only (R3-1, R5-2). |

### Reassessment of known risks

| ID | Risk | Phase 5 assessment |
|---|---|---|
| R4-1 | Honest provider unpaid if nobody reviews by `reviewDeadline` | **Economic/product trade-off, not a vulnerability.** No funds are lost or locked: the buyer is refunded, the provider's job closes with no fault and its stake is free (`LivenessTest.test_BuyerDisappears_NoVerifier_RefundNotPayment`). The provider can still be paid by a verifier, even after the deadline until someone closes the request (`test_BuyerDisappears_VerifierApproves_ProviderPaid`). Requires verifier SLAs shorter than `reviewPeriod` (7 days by default). Unchanged. |
| R4-2 | Single verifier can approve fake or reject genuine evidence | **Trust assumption.** Authorization is correct: the role is checked on both the marketplace and PoS, conflict of interest is checked twice, and the live role is re-read (a revoked verifier is rejected mid-flow). Consequences are bounded to paying the escrowed amount to the bound provider or refunding the buyer. Verifier consensus is not added, because no Phase 5 finding requires it. |
| R4-3 | Fault flag on a verifier refund comes from the marketplace | **Cannot be spoofed.** `recordOutcome` is marketplace-only (16-actor matrix). The flag comes only from `resolveDispute` (marketplace `VERIFIER_ROLE`, non-party), `expireRequest` (always `true`) and the timeouts (always `false`). Reputation validates it against the status (`InvalidOutcome`). A wrong flag needs a dishonest verifier (R4-2). Mutation M3 (expiry recorded as no-fault) was caught. |
| R4-4 | Evidence authenticity/storage offchain | **Correctly scoped.** The chain stores only the provider's commitment, an onchain-computed bound hash, timestamps and the reviewer. It claims integrity and timing, not truth. P5-5 adds the manifest requirement. |
| R5-1 (new) | **Compromised admin** can self-grant `VERIFIER_ROLE` on both contracts, admit a sybil provider, take undirected OPEN requests and approve its own fake proofs | **Residual centralization risk, kept as an executable test** (`AdversarialTest.test_AdminCompromise_KnownRisk_SybilCanBePaidForUndirectedRequests`). Bounded: directed and already-accepted requests, stake, credits, proofs and reputation are untouchable, and the admin key itself never receives funds. Mitigation is deployment, not code: a multisig admin behind a timelock (role grants become delayed and public), `RoleGranted` monitoring, and directed requests for high-value work. |
| R5-2 (new) | Without a live verifier, a provider can open a dispute just before its service deadline, turning a certain `failedJobs` expiry into a no-fault timeout; the buyer's refund is delayed by up to `disputePeriod` | **Deliberate trade-off.** Dispute timeouts are no-fault by design (same root as R3-1). With a live verifier the fault is recorded, and `disputes` still increments. Executable: `test_Provider_DisputeToAvoidFault_KnownRisk`. |
| R5-3 (new) | Raw commitment single-use per deployment only | Offchain requirement (P5-5). |
| R5-4 (new) | Circle can freeze USDC held by the escrow itself | **External trust assumption.** Transitions still complete and credits are preserved; nothing is withdrawable until the freeze is lifted (`test_Blacklist_EscrowItselfFreezesWithdrawalsOnly`). |
| OI-2 / R-4 | Admin self-grants verifier | Superseded by R5-1, which demonstrates the full consequence. Still present. |
| OI-3 / R-3 | Colluding verifier and provider | Unchanged trust assumption. Colluding *registry* verifiers can only admit providers; payment still needs a marketplace verifier or the buyer. |
| OI-4 / R-5 | Lost provider key | Unchanged: stake and credit are unrecoverable without the key (no admin override, by design). Smart-account wallets are recommended. |
| R-6 | Direct token transfers | Tested: escrow surplus is inert, registry donations are not stake, and marketplace/PoS/reputation balances are stranded. No rescue function is added, because it would give the admin a token path. |
| OI-5 / R-7 | USDC pause/blacklist | Tested with mocks **and with Circle's real controls on the fork**. Pull payments plus `withdrawTo` isolate the affected address. |
| R-9 / R3-6 | No static analysis | **Resolved:** Slither and Aderyn ran (below). |
| R3-5 | No fork test of the full flow | **Resolved:** full flow against real Arbitrum Sepolia USDC (below). |
| — | No external audit; no production deployment | **Still open.** |

### Tests added in Phase 5

| Suite | Tests | What it covers (section of the Phase 5 brief) |
|---|---|---|
| `Clinova.system.invariant.t.sol` | 9 invariants (128 runs × 128 depth = 16,384 calls) + 2 random-campaign tests | §5 A–F, §18, §19. The handler drives all five contracts *and* the full provider lifecycle, verifier grants/revocations mid-flow, bounded admin changes, pause/unpause of both contracts, `withdrawTo`, donations, commitment replay/copying and 20 attacks. |
| `StateMachine.t.sol` | 20 | §17: 15 request states × 16 actions against an explicit table, with cross-module agreement after each transition; the proof, escrow and job machines are driven directly. |
| `AuthorizationMatrix.t.sol` | 15 | §16: every mutating function × 16 actors (parties, outsiders, partial-role verifiers, admin, pauser, the five contract addresses). |
| `Adversarial.t.sol` | 22 | §6: buyer, provider, verifier and admin attacks; two executable known-risk tests (R5-1, R5-2). |
| `Liveness.t.sol` | 15 | §7–10: zero verifiers, verifier removed at each stage, admin renounced, buyer or provider disappears, pause at every stage. |
| `MaliciousToken.t.sol` | 17 | §11–13: hook-token reentrancy (double withdraw, stake-exit re-entry, half-funded request), false-return, reverting, no-return, lying and blacklist/pause tokens, direct transfers; P5-1 regression. |
| `BoundariesAndReplay.t.sol` | 15 (including 1 fuzz) | §14–15: every deadline at −1/0/+1 s, creation bounds, snapshots, `block.number` irrelevance; replay across requests, providers, deployments and chains; proof-hash injectivity. |
| `DeployScript.t.sol` | 8 | §21: nonce prediction from any starting nonce, misprediction fails closed, `verify()` guards, env parsing. |
| `fork/ArbitrumSepolia.fork.t.sol` | 6 | §20: real Circle USDC on an Arbitrum Sepolia fork. |

**Non-vacuity.** The system handler reverts when an action's protocol call fails, so Forge's invariant metrics report real successes (calls − reverts) in the random campaign. One full run (16,384 calls) recorded: create 457, accept 147, start 105, submitProof 146, confirm 103, approve 90, reject 94, dispute 160, resolve 179, cancel 168, expire 312, closeUnreviewed 47, timeout 105, withdraw 236, stake withdrawals 43, deposits 400, activations 250, unstake requests 194, verifier role toggles 556, pauses/unpauses 253. `test_RandomCampaignsReachEveryState` additionally requires three pseudo-random 450-step campaigns (no scripted steps) to reach escrow RELEASED and REFUNDED, every final proof state, a terminal dispute, an expired accepted job, a cancellation, a non-zero `failedJobs`, a stake withdrawal and a provider payment withdrawal.

**Mutation check of the new tests** (each mutant compiled with `forge build --force`):

| Mutant | Caught by |
|---|---|
| M1: `withdrawStake` ignores open obligations | `invariant_H_NoViolations` ("stake withdrawn with an open obligation") |
| M2: a no-fault dispute counted as `failedJobs` | `invariant_F_ReputationConsistency` |
| M3: expiry after acceptance recorded as no-fault | `invariant_I_NoPermanentLock` (the expiry reverts in reputation, so funds would lock) |
| State matrix: provider allowed to dispute COMPLETED; a legal transition marked forbidden | `test_Matrix_Completed` (both directions) |
| Authorization matrix: wrong allowed set | `test_Auth_Market_BuyerFunctions` |

### Fork testing (Arbitrum Sepolia)

| Item | Value |
|---|---|
| RPC | Public `https://sepolia-rollup.arbitrum.io/rpc` (the documented official endpoint; no credentials) |
| Chain ID | 421614 (asserted) |
| Fork point | Latest at run time (L2 head ≈ 314,632,715). `block.number` inside the EVM reported 11,821,739, the L1 estimate Arbitrum returns, which is why the contracts never use it. Set `FORK_BLOCK` to pin. |
| USDC | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`, from `.env.example` and `arbitrum-research.md` (source: developers.circle.com/stablecoins/usdc-contract-addresses), re-checked onchain: symbol USDC, 6 decimals, FiatToken v2 |
| Real USDC used? | Yes: Circle's deployed FiatToken contract and state on the fork. Test balances were created through the token's own `masterMinter → configureMinter → mint` path, not storage writes. Nothing was broadcast. |
| Flows | (1) register → stake → verify → activate → create + fund → accept → start → proof → verifier approve → release → withdraw → reputation → unstake → withdraw stake; (2) buyer confirmation; (3) dispute → `REFUND_PROVIDER_FAULT`, dispute timeout, unreviewed close (refund); (4) Circle's real blacklist → `withdrawTo`; (5) Circle's real pause; (6) direct transfer → surplus. Plus the Phase 1 metadata check. |
| Result | 7/7 passed |
| Blocker | None. The suite skips automatically when `ARB_SEPOLIA_RPC_URL` is unset. |

### Static analysis

| Tool | Result | Triage |
|---|---|---|
| `forge lint` | Same 4 warnings as the baseline | Unchanged triage (2 false positives, 2 intentional) |
| Slither 0.11.6 (102 detectors, `src` only) | 5 results | 4 × `timestamp`: intentional, hours/day-scale windows (arbitrum-research.md). 1 × `reentrancy-events` in `submitProof`: the event follows the call to the immutable ProofOfService, which only makes view calls back. Accepted. |
| Aderyn 0.6.8 (88 detectors, run in WSL because the npm package does not support Windows) | 1 High, 5 Low | **H-1 "state change after external call" (8 instances): false positive.** Constructors set immutables after view calls during construction, and `ReputationRegistry.recordOutcome` writes after `view` calls to the immutable registry, marketplace and PoS. Solidity emits `STATICCALL` for `view` interface calls, so the callee cannot modify state or re-enter. **L-5 "unsafe ERC20 operation": false positive**; it flags `proofOfService.approve(...)`, a name collision with ERC-20 `approve`. L-1 centralization: documented roles (R5-1). L-2/L-4 loop with revert in `register`: intentional (caller's own gas and record). L-3 single-use modifier: style. |

### Gas and storage review

Only meaningful observations are listed. No change was made, because none outweighs readability or defence in depth.

- **No unbounded loops or growing arrays.** The only loop is the caller-supplied capability list in `register`, which runs on the caller's gas and writes only its own record.
- **Settlement costs about 230k gas** (`confirmCompletion`/`approveProof`). About eight cross-module calls are deliberate defence in depth: ProofOfService and ReputationRegistry each re-read the full 6-slot request through `getRequest`. A narrower view (buyer and provider only) would save a few thousand gas per call, at the cost of more API surface. On Arbitrum, L2 execution is cheap and the calldata here is a single id, so this is not worth doing now.
- `createRequest` costs about 250k gas: the 6-slot request, the 3-slot deposit and three `balanceOf` reads (the double arrival check is intentional).
- `ProofOfService` stores `proofHash` even though it can be recomputed from stored fields: one extra slot per proof, kept for indexers and direct reads.
- `Deposit` uses 3 slots. Packing it into 2 would need a `uint96` amount, which is not worth the type change.

### Final results

| Check | Result |
|---|---|
| `forge fmt --check` | pass |
| `forge build` | pass |
| `forge test` | **414 passed, 0 failed, 7 skipped** (the 7 RPC-gated fork tests, which pass when run with the RPC) |
| Unit / scenario tests | 392 (including 13 integration, 8 deploy-script, and 2 handler smoke/reach tests) |
| Fuzz tests | 19 (1,000 runs each, except the random-campaign fuzz at 16 runs × 500 steps) |
| Invariant campaigns | 3 suites, 33 invariants, 49,152 random calls, 0 violations |
| Fork tests | 7 passed (with `ARB_SEPOLIA_RPC_URL`) |
| `forge coverage` (src) | **100%** lines (540/540), statements (668/668), branches (120/120), functions (99/99) |
| `forge lint` | 4 warnings, all triaged (unchanged) |
| Slither / Aderyn | Reviewed above; no true positive |

### Deployment readiness (Arbitrum Sepolia)

**Ready for an Arbitrum Sepolia testnet deployment**, with these preconditions:

1. Use a fresh deployer key that sends no other transaction during the deployment (nonce prediction). The script now fails closed and verifies the result.
2. `ADMIN_ADDRESS` should already be the multisig intended for production (ideally behind a timelock), even on testnet, so the role-management flow is exercised.
3. After deployment, the admin grants `VERIFIER_ROLE` and `PAUSER_ROLE` on **both** the registry and the marketplace, and a monitor watches `RoleGranted`.
4. Verifier operations must commit to an SLA shorter than `reviewPeriod` (R4-1) and must check the evidence manifest (P5-5).

**Not ready for mainnet:** there is no external audit and no production deployment history, and the admin-compromise path (R5-1) relies on operational controls.

## Code review checklist (apply to every PR)

- [ ] Every external state-changing function checks status, actor and deadline, in that order, before any effect.
- [ ] CEI order holds, and `nonReentrant` is on every token-moving function.
- [ ] No `string`/`bytes` parameters or events. No `tx.origin`. No `block.number`.
- [ ] No admin path to tokens. No mutable module addresses.
- [ ] Invariants I1 to I12 are covered by fuzz or invariant tests.
- [ ] Events emitted for every transition, matching the spec.
