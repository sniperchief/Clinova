# Clinova Contract Specification

Status: **Phase 5.** All five contracts are implemented and match this document: `ProviderRegistry` (Phase 2), `ServiceMarketplace` and `ClinovaEscrow` (Phase 3), `ProofOfService` and `ReputationRegistry` (Phase 4). Phase 5 was a security pass: the only behavioural change is the `withdrawTo` recipient check (§4, P5-1); see [security-review.md](security-review.md).

> Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion. The blockchain does not itself prove that a medical service happened.

Conventions:

- Amounts are USDC base units (6 decimals).
- Times are `uint64` unix seconds from `block.timestamp`. `block.number` is never used, because on Arbitrum it returns an approximate L1 block number.
- All errors are custom errors.
- Every state change emits an event.
- There is no `string` in any external function or event.

## 1. Request state machine (Phase 3, updated in Phase 4)

Source: `contracts/src/ServiceMarketplace.sol`. Interface: `contracts/src/interfaces/IServiceMarketplace.sol`.

```solidity
enum Status { NONE, OPEN, ACCEPTED, IN_SERVICE, COMPLETED, SETTLED, CANCELLED, EXPIRED, DISPUTED, REFUNDED }
```

- `NONE = 0` means "does not exist". Request IDs start at 1.
- **Terminal states** are `SETTLED`, `CANCELLED`, `EXPIRED` and `REFUNDED`. Each is absorbing and has a matching terminal escrow state (§4). A terminal state never leaves a proof in `SUBMITTED` (§8).
- **The fixed price is immutable.** `price` is set once at creation, equals the escrowed amount, and has no setter.
- **Deadlines use `block.timestamp`.** An action "before X" is allowed while `now <= X`. An exit "after X" is allowed only when `now > X`.
- **Payment requires positive acceptance (Phase 4).** A provider is paid only when one of these happens:
  - the buyer confirms;
  - a non-party verifier approves the proof;
  - a verifier resolves a dispute in the provider's favor, which is only possible while the proof is still `SUBMITTED`.

  **An unreviewed completion is never paid.**

```text
                 createRequest (+USDC escrowed atomically)
                          │
   CANCELLED ◄── buyer ── OPEN ── anyone, now > acceptDeadline ──► EXPIRED
                          │ acceptRequest (provider = msg.sender, registry-eligible, now <= acceptDeadline)
                          ▼
                      ACCEPTED ──┐                 buyer|provider, now > serviceDeadline
                          │ startService ├──────────────────────────────────────────────► EXPIRED (provider fault)
                          ▼              │
                      IN_SERVICE ────────┤  openDispute (buyer|provider, now <= serviceDeadline)
                          │ submitProof  │
                          │ (PoS: SUBMITTED)
                          ▼              ▼
                      COMPLETED ───► DISPUTED ── resolveDispute(PROVIDER_WINS; proof SUBMITTED → APPROVED) ─► SETTLED
         openDispute (buyer, ≤ review)   │  ▲ submitProof into dispute (from ACCEPTED/IN_SERVICE)
         rejectProof (verifier; proof    │  ├── resolveDispute(REFUND_*; proof → REJECTED) ──────────────────► REFUNDED
                      → REJECTED)        │  └── resolveDisputeByTimeout (anyone, now > disputeDeadline) ──────► REFUNDED
                          │
     confirmCompletion (buyer; proof → BUYER_ACCEPTED) | approveProof (verifier; proof → APPROVED) ──► SETTLED
     closeUnreviewed (anyone, now > reviewDeadline; proof → UNRESOLVED) ─────────────────────────────► REFUNDED
```

### Transition table

`V` = holder of the marketplace's `VERIFIER_ROLE` who is **neither the buyer nor the provider** of the request. This is checked by the marketplace, and independently again by ProofOfService.

"Close job" means `registry.recordJobClosed(id, request.provider)`. "Record" means `reputation.recordOutcome(id, providerAtFault)` (§9).

| # | From → To | Function | Actor | Conditions | Effects |
|---|---|---|---|---|---|
| T1 | NONE → OPEN | `createRequest(...)` | Any buyer | Unchanged from Phase 3: not paused, valid hashes, `price >= minPrice`, window bounds | USDC buyer → escrow, `escrow.lock`, periods snapshotted |
| T2 | OPEN → ACCEPTED | `acceptRequest(id)` | Provider = `msg.sender` | Not paused, `now <= acceptDeadline`, not the buyer, directed match; **registry checks eligibility** | Binds provider (registry job, escrow payee) |
| T3 | OPEN → CANCELLED | `cancelRequest(id)` | Buyer | none | `escrow.refund` |
| T4 | OPEN → EXPIRED | `expireRequest(id)` | Anyone | `now > acceptDeadline` | `escrow.refund` (to the buyer) |
| T5 | ACCEPTED → IN_SERVICE | `startService(id)` | Assigned provider | `now <= serviceDeadline` | none |
| T6 | IN_SERVICE → COMPLETED | `submitProof(id, evidenceCommitment)` | Assigned provider | `now <= serviceDeadline`. PoS: commitment ≠ 0, first proof for the request, commitment not used by this provider before. | PoS `SUBMITTED` with an onchain-bound `proofHash`. `reviewDeadline = now + reviewPeriod`. |
| T7 | COMPLETED → SETTLED | `confirmCompletion(id)` | Buyer | none | `escrow.release`, close job, record(success), PoS `BUYER_ACCEPTED` |
| T8 | COMPLETED → SETTLED | `approveProof(id)` | V | none (allowed until T9 executes) | `escrow.release`, close job, record(success), PoS `APPROVED` |
| T9 | COMPLETED → REFUNDED | `closeUnreviewed(id)` | Anyone | `now > reviewDeadline` | `escrow.refund`, close job, record(no fault), PoS `UNRESOLVED` |
| T10 | ACCEPTED / IN_SERVICE → DISPUTED | `openDispute(id, reasonHash)` | Buyer or assigned provider | `now <= serviceDeadline`. `reasonHash ≠ 0`. | `disputedFrom`, `disputeDeadline` |
| T11 | COMPLETED → DISPUTED | `openDispute(id, reasonHash)` | Buyer only | `now <= reviewDeadline` | Same as T10. The proof stays `SUBMITTED`. |
| T12 | COMPLETED → DISPUTED | `rejectProof(id, reasonHash)` | V | `reasonHash ≠ 0` (allowed until T9 executes) | Same as T10, PoS `REJECTED` (final) |
| T12b | DISPUTED → DISPUTED | `submitProof(id, evidenceCommitment)` | Assigned provider | `disputedFrom ∈ {ACCEPTED, IN_SERVICE}`, `now <= serviceDeadline`, PoS rules as in T6 | PoS `SUBMITTED` (dispute evidence) |
| T13 | DISPUTED → SETTLED | `resolveDispute(id, PROVIDER_WINS)` | V | **Proof is `SUBMITTED`**; never NONE, never REJECTED (`ProofNotApprovable`) | `escrow.release`, close job, record(success), PoS `APPROVED` |
| T14 | DISPUTED → REFUNDED | `resolveDispute(id, REFUND_PROVIDER_FAULT \| REFUND_NO_FAULT)` | V | none | `escrow.refund`, close job, record(fault flag), a `SUBMITTED` proof becomes `REJECTED` |
| T15 | ACCEPTED / IN_SERVICE → EXPIRED | `expireRequest(id)` | Buyer or assigned provider | `now > serviceDeadline` | `escrow.refund`, close job, record(**provider fault**) |
| T16 | DISPUTED → REFUNDED | `resolveDisputeByTimeout(id)` | Anyone | `now > disputeDeadline` | `escrow.refund`, close job, record(no fault), a `SUBMITTED` proof becomes `UNRESOLVED` |

**Every other (state, function) pair reverts.** There is no status setter on any contract.

**Call ordering.** Marketplace effects and events happen first. The calls to escrow, registry, reputation and ProofOfService follow, and any revert in them reverts the whole transaction.

### Dispute resolution

This is unchanged from Phase 3, apart from the proof constraints:

- `disputeDeadline` is snapshotted when the dispute opens.
- Verifiers can resolve until the timeout executes.
- The timeout refunds the payer as **unresolved and no-fault**.
- A `PROVIDER_WINS` resolution now also requires the proof to still be under review, so **a proof a verifier already rejected can never lead to payment**.

### Phase 4 changes to the state machine

| Change | Reason |
|---|---|
| **`finalizeSettlement` is removed. `closeUnreviewed` (T9) refunds instead of paying.** | This fixes Phase 3 risk **R3-3**, where an unchallenged fake completion was eventually paid. Payment now always needs positive acceptance. Liveness is kept: an unreviewed completion ends as a no-fault refund, so escrow cannot lock. |
| `rejectProof` and `approveProof` are allowed after `reviewDeadline`, until T9 executes | Late verifier action is still useful. T9 now refunds rather than pays, so there is nothing to race. |
| T13 requires a `SUBMITTED` proof | A rejected proof is final: `REJECTED` never becomes `APPROVED` |
| Proof storage and replay protection moved to `ProofOfService`; `proofHashOf` and `proofHashUsed` are removed from the marketplace | Single source of truth for proofs. Nothing was deployed, so the removal is safe. |
| `submitProof` takes an `evidenceCommitment`, and the bound `proofHash` is computed onchain | The request/provider binding is enforced by the contract, not left to an offchain convention (§5) |

## 2. ProviderRegistry (implemented in Phase 2)

Source: `contracts/src/ProviderRegistry.sol`. Interface: `contracts/src/interfaces/IProviderRegistry.sol`.

### Provider states

| Flag | Meaning | Set by | Cleared by |
|---|---|---|---|
| `registered` | A provider record exists for this wallet. It is permanent: there is no re-registration and no transfer. | `register` (self) | never |
| `verified` | A verifier has checked the provider's offchain profile and claimed capabilities | `verifyProvider` (verifier) | `revokeVerification` (verifier), `updateProfile` (self), `addCapability` (self) |
| `active` | The provider has opted in to receiving new requests | `activate` (self) | `deactivate` (self), `requestUnstake` (self), any verification revocation |
| `unstakeAvailableAt != 0` | The provider is unbonding | `requestUnstake` (self) | `withdrawStake` (self) |

**Maintained invariant:** if a provider is active, then it is registered, verified and not unbonding.

### Eligibility rule

```text
eligible(provider, serviceType) =
    registered && verified && active && unstakeAvailableAt == 0
    && stake >= minStake (current value) && offersService[provider][serviceType]
```

### Lifecycle

```text
register(+stake >= minStake) --> verifyProvider (verifier) --> activate (self) --> ELIGIBLE
   (starts unverified, inactive)

From an eligible (or any registered) provider:
  updateProfile / addCapability / revokeVerification --> unverified + inactive (needs re-verification)
  deactivate                                         --> inactive (provider may re-activate)
  requestUnstake --> unbonding --> withdrawStake (full stake, requires activeJobs == 0)
                                     --> depositStake --> activate (still verified)
```

### Functions

| Function | Actor | Conditions (in check order) | Effects / events |
|---|---|---|---|
| `register(metadataHash, locationHash, capabilities[], stakeAmount)` | Any wallet, registering itself | Not paused. Caller ≠ marketplace. Not registered. Both hashes ≠ 0. `stakeAmount >= minStake`. Each capability ≠ 0 and unique. | Creates the record (unverified, inactive), adds capabilities, and pulls exactly `stakeAmount` USDC. Emits `ProviderRegistered`, `ProviderCapabilityAdded`×n, `ProviderStakeDeposited`. |
| `updateProfile(metadataHash, locationHash)` | Provider | Registered. Hashes ≠ 0. | Emits `ProviderProfileUpdated`. **Revokes verification**, which deactivates if active. |
| `addCapability(serviceType)` | Provider | Registered. ≠ 0. Not already offered. | Emits `ProviderCapabilityAdded`. **Revokes verification**, because new claims must be re-verified. |
| `removeCapability(serviceType)` | Provider | Registered. Currently offered. | Emits `ProviderCapabilityRemoved`. Verification is kept, since narrowing claims is always safe. |
| `depositStake(amount)` | Provider | Not paused. Registered. `amount > 0`. Not unbonding. | Pulls exactly `amount`. Emits `ProviderStakeDeposited`. |
| `activate()` | Provider | Registered. Not active. Verified. Not unbonding. `stake >= minStake`. | Emits `ProviderActivated`. |
| `deactivate()` | Provider | Registered. Active. | Emits `ProviderDeactivated(SELF)`. `activeJobs` is unaffected. |
| `requestUnstake()` | Provider | Registered. Not unbonding. `stake > 0`. | Sets `unstakeAvailableAt = now + unbondingPeriod` (a snapshot), deactivates, and emits `UnstakeRequested`. |
| `withdrawStake()` | Provider | Unbonding. `now >= unstakeAvailableAt`. `activeJobs == 0`. **Not pausable.** | Transfers the full stake to `msg.sender` and resets the unbonding state. Emits `ProviderStakeWithdrawn`. |
| `verifyProvider(provider)` | `VERIFIER_ROLE` | Registered. Verifier ≠ provider. Not already verified. | Changes only `verified`. Emits `ProviderVerified`. |
| `revokeVerification(provider)` | `VERIFIER_ROLE` | Registered. Verified. | Clears `verified` and deactivates. Stake and `activeJobs` are untouched. Emits `ProviderVerificationRevoked` and `ProviderDeactivated(VERIFICATION_REVOKED)`. |
| `recordJobAccepted(requestId, provider, serviceType)` | Marketplace (immutable address) | Request ID never bound before (`JobAlreadyRecorded`). **The registry re-checks full eligibility itself.** | Binds `requestId → provider` (OPEN). `activeJobs++`. Emits `JobOpened`. |
| `recordJobClosed(requestId, provider)` | Marketplace | Job is OPEN (`JobNotOpen`). `provider` equals the bound provider (`JobProviderMismatch`). | Job becomes CLOSED (never reopenable). `activeJobs--`. Emits `JobClosed`. |
| `setMinStake` / `setUnbondingPeriod` | `DEFAULT_ADMIN_ROLE` | Within bounds (§3) | Emits `ParameterUpdated`. Never touches existing stake or pending unbonding. |
| `pause` / `unpause` | `PAUSER_ROLE` | none | Blocks **only** `register` and `depositStake` |

**Verification is reversible.** Only `VERIFIER_ROLE` can grant or revoke it. A provider implicitly gives it up by changing what was verified (its profile or capabilities). There is no separate admin deactivation: the admin acts only by granting or revoking verifier roles.

**Marketplace scope.** The marketplace can only open a job (once per request ID, for a currently eligible provider) or close that exact `(requestId, provider)` job. It cannot move stake, change flags or profile data, or act as a provider (`register` rejects the marketplace address, and every provider function keys on `msg.sender`).

**Phase 3 integration (done):** the marketplace passes the accepting `msg.sender` as `provider`, and closes the job with `request.provider` on every terminal transition from an accepted state (T7–T9, T13–T16). The registry rejects a close for the wrong provider, a double close, and re-binding a request ID. The invariant tests confirm that `activeJobs` always matches the marketplace lifecycle.

### Pause behavior (registry)

| Blocked while paused | Allowed while paused |
|---|---|
| `register`, `depositStake` | `withdrawStake`, `requestUnstake`, `activate`, `deactivate`, `updateProfile`, `add/removeCapability`, `verifyProvider`, `revokeVerification`, `recordJobAccepted`, `recordJobClosed`, admin setters |

Pause blocks new money coming in. It never blocks money going out or in-flight obligations. The marketplace applies its own pause to new acceptances.

### Phase 2 changes to the Phase 1 registry design

| Phase 1 | Implemented | Reason |
|---|---|---|
| `register` required no stake | `register` requires an initial stake `>= minStake`, taken atomically | Stops unstaked spam registrations that consume verifier effort. The lifecycle stays register → stake → verify → activate, with the first two combined into one transaction. |
| `setActive(true)` did not require verification | `activate()` requires verified, stake `>= minStake`, and no pending unstake | Closes the "activation before verification" path |
| `setServiceOffered` could add claims after verification | `addCapability` revokes verification; `removeCapability` does not | New capability claims would otherwise bypass the verifier |
| `updateProfile` cleared `verified` only | It also deactivates | Keeps the invariant that an active provider is verified |
| `incrementActiveJobs` had no checks | `recordJobAccepted` re-checks full eligibility | The marketplace cannot bypass registry rules |
| `setVerified(bool)`, `setActive(bool)`, `setServiceOffered(bool)` | Split into explicit functions that revert on no-op | Clear events and errors; repeated verification reverts |
| `MAX_SERVICES` cap | Removed | The loop runs on the caller's own gas and only writes the caller's own record, so there is no DoS surface |
| Deposit accounting | Balance-delta check (`TransferAmountMismatch`) | Rejects fee-on-transfer or misbehaving tokens. Same rule as `ClinovaEscrow.lock`. |

## 3. Parameters

All parameters are admin-settable **within hard-coded bounds**, and every change emits `ParameterUpdated`. Request-level values are **snapshotted at creation**, so no admin action changes an existing request.

| Parameter | Contract | Bounds | Default (deploy script) | Applies to |
|---|---|---|---|---|
| `minStake` | Registry | `0 < x <= 100_000e6` | 100 USDC | Eligibility for future acceptances |
| `unbondingPeriod` | Registry | 1 to 30 days | 7 days | Snapshotted at `requestUnstake` |
| `minPrice` | Marketplace | 1 to 10,000 USDC | 1 USDC | New requests |
| `reviewPeriod` | Marketplace | 1 to 14 days | 7 days | Snapshotted into each request. The window for buyer disputes and verifier review; after it, an unreviewed completion closes as a no-fault refund. |
| `disputePeriod` | Marketplace | 3 to 60 days | 14 days | Snapshotted into each request |
| Accept window | Marketplace (constant) | 1 hour to 7 days | n/a | Buyer-chosen, validated |
| Service window | Marketplace (constant) | 6 hours to 30 days | n/a | Buyer-chosen, validated |

**Protocol fee:** none in the MVP.

## 4. Escrow and module authority (implemented in Phase 3)

Source: `contracts/src/ClinovaEscrow.sol`. The escrow has **no admin, no roles, no pause and no rescue function**.

### Escrow lifecycle (per request, independent of the marketplace status)

```text
NONE ──lock──► FUNDED ──assignPayee (once)──► FUNDED(payee bound)
                 │                                   │
                 └───────────refund─────────► REFUNDED   (credit → payer)
                                                     └──release──► RELEASED (credit → bound payee)
```

| Function | Caller | Checks (the escrow defends itself) | Effect |
|---|---|---|---|
| `lock(id, payer, amount)` | Marketplace | State is NONE. `payer ≠ 0`. `amount > 0`. **`surplus() >= amount`**, meaning the tokens must already have arrived; the escrow never trusts `amount`. `amount ≤ uint128`. | FUNDED. `totalLocked += amount`. |
| `assignPayee(id, payee)` | Marketplace | FUNDED. No payee yet. `payee ∉ {0, payer}`. | Binds the **only** address `release` can pay |
| `release(id)` | Marketplace | FUNDED. Payee bound. | RELEASED. Moves the full deposit from locked to `credit[payee]`. Takes no amount or recipient argument. |
| `refund(id)` | Marketplace | FUNDED | REFUNDED. Moves the full deposit from locked to `credit[payer]`. |
| `withdraw()` / `withdrawTo(r)` | Any account | `credit[msg.sender] > 0`. `r ≠ 0` (`ZeroAddress`). `r ∉ {escrow, marketplace}` (`InvalidRecipient`, Phase 5: tokens sent there could never be moved again). | Zeroes the credit, then transfers (CEI, `nonReentrant`). **Never paused.** |

**Accounting identity:** `usdc.balanceOf(escrow) == totalLocked + totalCredited + surplus`. `surplus` is only ever tokens sent directly to the escrow, and it is never credited to anyone. The invariant tests check this as **exact equality**, against an independently tracked donation total.

**Funding path:** the buyer approves the **marketplace** (not the escrow). The marketplace calls `usdc.safeTransferFrom(msg.sender, escrow, price)`, checks that the escrow's balance delta equals `price`, and then calls `escrow.lock`. The escrow independently checks that the tokens arrived. In the whole system, the only `transferFrom` for payments uses `from = msg.sender`.

### Authorization matrix

| Action | Buyer | Provider | Anyone | Marketplace contract | Verifier | Admin |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Create and fund request | ✓ | | | | | |
| Accept request | | ✓ (as itself, if eligible) | | | | |
| Start service / submit proof | | ✓ (assigned) | | | | |
| Cancel (OPEN) | ✓ | | | | | |
| Expire OPEN (after acceptDeadline) | ✓ | ✓ | ✓ | | | |
| Expire ACCEPTED/IN_SERVICE (after serviceDeadline) | ✓ | ✓ (assigned) | | | | |
| Open dispute (ACCEPTED/IN_SERVICE) | ✓ | ✓ (assigned) | | | | |
| Open dispute (COMPLETED) | ✓ | | | | | |
| Confirm completion (settle) | ✓ | | | | | |
| Approve / reject proof | | | | | ✓ (non-party) | |
| Close unreviewed completion (refund) | | | ✓ | | | |
| Resolve dispute | | | | | ✓ (non-party) | |
| Dispute timeout (refund) | | | ✓ | | | |
| `escrow.lock/assignPayee/release/refund` | | | | ✓ (immutable address) | | |
| `registry.recordJobAccepted/Closed` | | | | ✓ (immutable address) | | |
| `proofOfService.submit/approve/reject/markBuyerAccepted/markUnresolved` | | | | ✓ (immutable address; PoS re-checks provider, buyer, verifier role and independence) | | |
| `reputation.recordOutcome` | | | | ✓ (immutable address; once per finished accepted request) | | |
| Edit reputation or proof history | | | | ✗ | ✗ | **✗ (no function exists)** |
| Withdraw own escrow credit | ✓ | ✓ | ✓ (own credit only) | | | |
| Set bounded parameters, grant/revoke roles | | | | | | ✓ |
| Pause / unpause (new obligations only) | | | | | | Pauser role |
| Move escrow funds / edit request / move stake | | | | | | **✗ (no function exists)** |

### Pause matrix (marketplace)

| Blocked while paused | Allowed while paused |
|---|---|
| `createRequest`, `acceptRequest` | `startService`, `submitProof`, `confirmCompletion`, `approveProof`, `rejectProof`, `openDispute`, `resolveDispute`, `cancelRequest`, `expireRequest`, `closeUnreviewed`, `resolveDisputeByTimeout`, `escrow.withdraw/withdrawTo`. ProofOfService and ReputationRegistry have no pause. |

Pausing an in-flight step would let the pauser force deadline losses, so only new obligations are pausable. The escrow has no pause at all. The invariant test `invariant_NoPermanentLock` drains every reachable state **while paused**.

## 5. Proof commitment construction (normative)

```text
Offchain (provider / evidence service), never onchain:
  evidenceBundleHash = keccak256(encryptedEvidenceBundle)
  salt               = 32 random bytes, kept offchain with the evidence
  evidenceCommitment = keccak256(abi.encode("CLINOVA_EVIDENCE_V1", evidenceBundleHash, salt))

Onchain (ProofOfService.computeProofHash), computed by the contract:
  proofHash = keccak256(abi.encode(
      keccak256("CLINOVA_PROOF_V1"), block.chainid, address(ProofOfService), requestId, provider, evidenceCommitment))
```

- **Binding is enforced onchain.** The contract, not the submitter, binds the commitment to the domain, chain, deployment, request and provider. A proof can never be read as belonging to another request, provider or deployment.
- **Replay.** Each `(provider, evidenceCommitment)` pair can be used once. Reusing the same evidence on a second request reverts (`EvidenceAlreadyUsed`). The scope is per provider, so another provider copying a commitment cannot block its owner.
- **Privacy.** The salt keeps low-entropy evidence from being recovered by dictionary. The contract never needs, and never accepts, plaintext evidence. Only 32-byte commitments go onchain.
- **What it proves.** The commitment records *that* a specific evidence bundle existed and was committed by this provider for this request at this time. **It does not show that a medical service happened.** That judgment belongs to the authorized verification process, or to the paying buyer.
- **Scope of onchain replay protection (Phase 5, R5-3).** `evidenceUsed` is per deployment, and `evidenceCommitment` itself does not contain the request. The *proofHash* can never be confused across chains, deployments, requests or providers, but the same raw commitment could be submitted by the same provider to a different deployment or chain. Therefore the evidence bundle **must** carry a manifest naming `chainId`, the ProofOfService address, `requestId` and the provider address, and a verifier **must** check that manifest against the request before approving. A bundle that names another request is grounds for rejection.

## 6. Invariants

✅ means covered by Foundry invariant tests (random multi-actor call sequences) plus unit, fuzz and integration tests.

| # | Invariant | Status |
|---|---|---|
| I1 | **Escrow conservation**: `balance == totalLocked + totalCredited + donations` (exact) | ✅ |
| I2 | **Lock matches request**: `deposit.amount == price`; `totalLocked == Σ price` over open requests | ✅ |
| I3 | **No double settlement or refund**: one terminal escrow state; SETTLED ⇔ RELEASED | ✅ |
| I4 | **No payment without positive acceptance**: SETTLED ⇔ proof `APPROVED` or `BUYER_ACCEPTED` | ✅ |
| I5 | **Authorization**: unauthorized calls to any module never succeed (attacker, and buyer or provider holding `VERIFIER_ROLE` acting on its own request) | ✅ |
| I6 | **Provider binding**: one provider per request; escrow payee, registry job, proof provider and reputation attribution all equal the accepting provider | ✅ |
| I7 | **Verification independence**: approve and reject only by a non-party `VERIFIER_ROLE` holder, checked twice (marketplace and PoS) | ✅ + unit |
| I8 | **State integrity**: no transition outside the table; terminal request states and terminal proof states never change | ✅ |
| I9 | **Privacy**: no `string` or `bytes` in any external function or event, only `bytes32` commitments | Review |
| I10 | **Stake integrity** | ✅ (registry suite) |
| I11 | **Active-job accounting** matches the lifecycle | ✅ |
| I12 | **No permanent lock**: from any reachable state, paused, with no verifier and no admin, every request ends and all credit is withdrawable | ✅ |
| I13 | **Credit ownership**: `credit + withdrawn == Σ outcomes` per account | ✅ |
| I14 | **Global USDC conservation**; the marketplace, PoS and reputation hold no funds | ✅ + unit |
| I15 | **Proof binding**: `proof.provider ==` accepting provider; `proofHash == computeProofHash(id, provider, commitment)`; at most one proof per request | ✅ |
| I16 | **Proof/request agreement**: `REJECTED` ⇒ DISPUTED or REFUNDED; `UNRESOLVED` ⇒ REFUNDED; `SUBMITTED` ⇒ COMPLETED or DISPUTED; COMPLETED ⇒ `SUBMITTED` | ✅ |
| I17 | **Reputation = outcomes**: counters equal an independent record of outcomes kept by the test handler; exactly one outcome per finished accepted request; Σ `successfulJobs` == number of SETTLED requests | ✅ |
| I18 | **Escrow flow conservation (Phase 5)**: Σ funded == Σ released + Σ refunded + `totalLocked`; each deposit is observed moving only NONE → FUNDED → (RELEASED \| REFUNDED), and a release always credits the accepting provider | ✅ (system suite) |
| I19 | **Stake conservation across the whole protocol (Phase 5)**: registry balance == `totalStaked` + donations; per-provider stake == deposited − withdrawn; stake never leaves while the *marketplace* shows an open job for that provider | ✅ (system suite) |
| I20 | **Success means payment (Phase 5)**: per provider, value released to it == Σ price of its SETTLED requests; a provider that never accepted has all-zero counters | ✅ (system suite) |

## 7. Events

```solidity
// ServiceMarketplace
ServiceRequestCreated(id, buyer, directedProvider, serviceType, locationHash, price, acceptDeadline, serviceDeadline)
ServiceRequestFunded(id, buyer, amount)          ServiceRequestAccepted(id, provider)
ServiceRequestStarted(id, provider)              ServiceRequestCompleted(id, provider, proofHash, reviewDeadline)
DisputeEvidenceSubmitted(id, provider, proofHash)
ServiceRequestCancelled(id, refundAmount)        ServiceRequestExpired(id, by, fromStatus, refundAmount)
ServiceRequestDisputed(id, by, reasonHash, fromStatus, disputeDeadline)
DisputeResolved(id, verifier, resolution)        DisputeTimedOut(id, by)
CompletionClosedUnreviewed(id, by)
ServiceRequestSettled(id, provider, amount, path) // path: BUYER_CONFIRMED | VERIFIER_APPROVED | DISPUTE_RESOLVED
ServiceRequestRefunded(id, buyer, amount)
// ProofOfService
ProofSubmitted(requestId, provider, proofHash, evidenceCommitment, submittedAt)
ProofApproved(requestId, provider, verifier, proofHash)
ProofRejected(requestId, provider, verifier, proofHash, reasonHash)
ProofAcceptedByBuyer(requestId, provider, buyer, proofHash)
ProofUnresolved(requestId, provider, proofHash)
// ReputationRegistry
OutcomeRecorded(requestId, provider, outcome, proofSubmitted, disputed)
ReputationUpdated(provider, completedJobs, successfulJobs, failedJobs, disputes)
// ClinovaEscrow, ProviderRegistry: unchanged (see Phase 3)
```

No event carries healthcare data. Hashes are salted commitments, and reasons are `bytes32` references to offchain records.

## 8. ProofOfService (implemented in Phase 4)

Source: `contracts/src/ProofOfService.sol`. It has no admin, no roles of its own, no funds, and **no permission on the marketplace**.

```text
NONE ──submit──► SUBMITTED ──approve (verifier)───────────► APPROVED        (payment)
                     │──────reject (verifier)─────────────► REJECTED        (final; never pays)
                     │──────markBuyerAccepted (buyer)─────► BUYER_ACCEPTED  (payment)
                     └──────markUnresolved (timeout/close)► UNRESOLVED      (refund, no fault)
```

| Function (marketplace only) | Independent checks inside PoS |
|---|---|
| `submit(id, provider, commitment)` | Commitment ≠ 0. No proof yet for `id`. `provider == marketplace.getRequest(id).provider` (and ≠ 0). `(provider, commitment)` not used before. Computes and stores `proofHash`. |
| `approve(id, verifier)` / `reject(id, verifier, reason)` | Proof `SUBMITTED`. `verifier` holds `VERIFIER_ROLE` on the marketplace. `verifier` is not the request's buyer or provider. Records `reviewer` and `reviewedAt`. |
| `markBuyerAccepted(id, buyer)` | Proof `SUBMITTED`. `buyer == request.buyer`. |
| `markUnresolved(id)` | Proof `SUBMITTED` |

**Replacement: none.** There is one proof per request. `submit` never overwrites (`ProofAlreadySubmitted`), and terminal proof states never change (`ProofNotReviewable`).

**Why the marketplace calls PoS, and not the other way round.** Keeping the marketplace as the single entry point means PoS needs *no* marketplace permission, so it cannot trigger or influence settlement except by reverting. PoS remains the source of truth for proofs and validates every call against the marketplace's own state.

## 9. ReputationRegistry (implemented in Phase 4)

Source: `contracts/src/ReputationRegistry.sol`. It has no admin, no setters, no reset or delete functions, and no funds.

`recordOutcome(requestId, providerAtFault)` is callable only by the marketplace, **once per request** (`OutcomeAlreadyRecorded`), and only when:

- the registry's job for `requestId` is `CLOSED`;
- `request.provider == job.provider`;
- the status agrees with the fault flag: SETTLED requires `false`, EXPIRED requires `true`, REFUNDED accepts either. Anything else reverts (`InvalidOutcome`).

**The provider is taken from the registry's one-time acceptance binding, never from the caller.**

### Counting rules (one request contributes at most once to each counter)

| Outcome | completedJobs | successfulJobs | failedJobs | disputes |
|---|:-:|:-:|:-:|:-:|
| Settled: buyer confirmed / verifier approved | +1 | +1 | | |
| Settled: dispute → `PROVIDER_WINS` | +1 | +1 | | +1 |
| Expired after acceptance (missed service deadline; no proof can exist) | 0 | | **+1** | |
| Dispute → `REFUND_PROVIDER_FAULT` | +1 if a proof exists | | **+1** | +1 |
| Dispute → `REFUND_NO_FAULT` (e.g. frivolous buyer dispute) | +1 if a proof exists | | **0** | +1 |
| Proof rejected by verifier → any refund | +1 | | +1 only if `REFUND_PROVIDER_FAULT` | +1 |
| Dispute timeout (no verifier decision) | +1 if a proof exists | | **0** | +1 |
| Completion closed unreviewed (T9) | +1 | | **0** | 0 |
| Cancelled / expired while OPEN (never accepted) | not recorded | | | |

**Definitions:**

- `completedJobs`: the provider submitted a completion proof.
- `successfulJobs`: paid.
- `failedJobs`: the provider was *determined* to be at fault, either by its own missed deadline or by a verifier's `REFUND_PROVIDER_FAULT`.
- `disputes`: the request was contested, either by a party or by a verifier rejecting the proof. This is a neutral involvement count, **not** a fault count.

No subjective scores are computed onchain. Consumers derive their own ratios from these counters.
