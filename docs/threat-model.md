# Clinova Threat Model

Scope: the five core contracts as specified in [contract-spec.md](contract-spec.md), on Arbitrum Sepolia with Circle USDC. The offchain verification service is covered only where it touches the chain.

**Assets:**

- escrowed USDC;
- provider stake;
- integrity of request state and proofs;
- provider reputation;
- patient privacy.

T-numbers refer to the transition table in the spec. I-numbers refer to its invariants.

## Buyer

| Threat | Mitigation |
|---|---|
| **Malicious cancellation** (cancels after the provider has committed resources) | `cancelRequest` is only valid in OPEN (T3). After acceptance, the only buyer exits are a dispute (verifier-resolved) or expiry *after the provider missed its own deadline* (T15). |
| **Unauthorized refund** (refund to self while the provider is delivering) | A refund requires T3, T4, T14 or T15. Each is gated on status plus deadline, or on a verifier decision. `refund()` on Escrow is callable by the marketplace only. |
| **Refund race at the deadline** (the buyer calls `expireRequest` the instant `serviceDeadline` passes) | Only possible after the provider has missed the deadline. Windows are at least 6h and the provider sees the deadline at acceptance. |
| **Frivolous dispute to damage reputation or block payment** | Proofs can still be submitted into a dispute (T12b). `REFUND_NO_FAULT` leaves `failedJobs` unchanged. Disputes are only allowed before `serviceDeadline` (or within the review window). Dispute counts are visible per *buyer* through events. **Residual:** if *no verifier* acts before `disputeDeadline`, the timeout refunds the buyer, so a frivolous dispute succeeds when verifiers are absent (R3-1). |
| **Double funding** | Funding happens atomically inside `createRequest`. The escrow accepts `lock` only from state NONE (tested with direct `lock` calls by the marketplace address). |
| **Underfunding / fee-on-transfer token** | The marketplace checks that the escrow's balance delta equals `price` (`TransferAmountMismatch`), and the escrow checks that its unaccounted balance covers the amount (`DepositNotReceived`). One request can never be backed by another request's funds or by credited funds (tested). |
| **State manipulation** (acting on another buyer's request) | Every buyer action checks `msg.sender == request.buyer`. Request fields are immutable after creation except `provider` (set once at T2) and `status`. |
| **Self-dealing** (buyer = provider to farm reputation) | `acceptRequest` rejects `caller == buyer`. Sybil farming with a second wallet is still possible and bounded by stake and verification (offchain KYC). This is documented as residual. |

## Provider

| Threat | Mitigation |
|---|---|
| **Fake completion** (submits a proof without doing the work) | The proof is only a commitment. Payment needs verifier approval or buyer confirmation (T7/T8). The verifier reviews offchain evidence. Stake and reputation are at risk. **Residual: relies on the verifier (trust assumption).** |
| **Duplicate completion** | One proof per request. `submitProof` is only valid in IN_SERVICE (or once into a dispute, T12b). |
| **Proof replay** (reusing an old proof hash) | Each `(provider, evidenceCommitment)` is single-use (`evidenceUsed`), and the onchain `proofHash` binds chain ID, ProofOfService address, requestId and provider (spec §5). *(Corrected in Phase 5: this row previously described the removed Phase 3 `proofHashUsed`.)* |
| **Unauthorized proof** (submitting for someone else's request) | Checks `msg.sender == request.provider`. |
| **Accepting without capacity / unverified** | The eligibility check (spec §2) runs at acceptance. A profile update clears `verified`. |
| **Improper stake withdrawal** (withdraw while holding jobs, or skip unbonding) | `withdrawStake` requires `now >= unstakeAvailableAt` (a snapshot) and `activeJobs == 0`. `requestUnstake` deactivates first, so no new jobs can be accepted. |
| **Stake withdrawal to a different address** | Stake always goes to `msg.sender`, which is the provider key. There is no recipient parameter. |
| **Abandonment after acceptance** | The buyer recovers funds via T15 after `serviceDeadline`, and `failedJobs++`. |

## Verifier

| Threat | Mitigation |
|---|---|
| **Unauthorized verification** | `VERIFIER_ROLE` is required. Roles are managed only by the admin. |
| **Conflict of interest** | The verifier cannot act on a request where it is the buyer or provider, or verify itself as a provider. |
| **Malicious verification** (approving fake proofs, colluding with a provider) | Powers are bounded: it can only pay the *escrowed amount* to the *assigned provider*, and only if a proof exists. It cannot redirect funds. Every decision is a public event. The admin can revoke the role. **Residual trust assumption for the MVP.** Future options are multiple verifiers (k-of-n) or verifier staking. |
| **Proof replay across requests** | Proofs are bound to a request (spec §5) and the global uniqueness check applies. |
| **Verifier liveness failure** (no verifier resolves disputes) | **Resolved in Phase 3 (OI-1), revised in Phase 4.** An unreviewed completion is *refunded* after the review window (T9; it is never paid). Disputes time out to a no-fault refund after `disputeDeadline` (T16). Missed deadlines expire (T15). `invariant_NoPermanentLock` and the Phase 5 `invariant_I_NoPermanentLock` prove every request reaches a terminal state with no verifier and no admin. *(Corrected in Phase 5: this row previously said unreviewed completions settle to the provider.)* |

## Smart contracts

| Threat | Mitigation |
|---|---|
| **Reentrancy** | OZ `ReentrancyGuard` on every token-moving function. Checks-effects-interactions everywhere. USDC has no transfer hooks, but the guard stays anyway. Pull payments mean settlement makes no external calls to recipients. |
| **Double settlement** | I3: the deposit leaves FUNDED before crediting, and terminal states are absorbing. Invariant-tested (escrow state machine observed after every call in the Phase 5 system suite). |
| **Accounting errors** | Solidity 0.8 checked arithmetic. Tracked `totalLocked` and `totalCredited`. Invariants I1, I2, I10 and I11 are fuzz- and invariant-tested. |
| **Invalid transitions** | An explicit `require(status == X)` per function, and a single transition table (I8). `NONE = 0` prevents acting on nonexistent IDs. |
| **Token transfer failures** | `SafeERC20` for every transfer. `lock` verifies the balance delta. Pull payments isolate a blacklisted or paused recipient to their own withdrawal. |
| **USDC pause / blacklist by Circle** | External trust assumption. A blacklisted buyer or provider can't withdraw, but other users are unaffected. Withdrawals can go to an alternate recipient, `withdrawTo`, and only for the caller's own balance. |
| **Stuck funds** | I12: *every* non-terminal state has an exit that needs no admin and no verifier and works while paused (invariant-tested). The worst-case duration is set by bounded deadlines fixed at creation. Direct token donations are tracked as `surplus` and never credited, which does not break accounting. |
| **Unbounded loops / gas DoS** | All protocol operations are O(1). The only loop is the capability array in `register`, which runs on the caller's gas and writes only the caller's record, so there is no cross-user DoS. Discovery happens offchain via events. |
| **Cross-module spoofing** (someone calling `Escrow.release` directly) | Module writes are restricted to the `immutable` marketplace address, set at construction. It is not a role, so it cannot be granted. |
| **Deployment wiring error** | `Deploy.s.sol` precomputes the marketplace address. The marketplace constructor reverts (`InvalidWiring`) unless both modules name it as their marketplace and share one token. The integration tests deploy through the same script. |
| **Arbitrum timing** | `block.number` is not used; it returns an L1 estimate. Timestamps can skew by up to about +1h/-24h, so windows are hours-scale. |
| **Upgradeability risk** | Contracts are **non-upgradeable** in the MVP. Bugs need a redeploy and migration, but there is no upgrade key to abuse. |

## Admin

| Threat | Mitigation |
|---|---|
| **Arbitrary fund withdrawal** | No admin function transfers tokens. There is no `rescueTokens`, no `sweep`, and no upgrade proxy. |
| **Privilege escalation** (granting itself the marketplace capability) | The marketplace capability is an immutable address, not a role. The admin *can* grant itself `VERIFIER_ROLE`, and that is equivalent to verifier power (bounded, as above). This is a documented residual risk; mitigated by a multisig admin and public `RoleGranted` events. |
| **Admin key compromise or instant takeover** | `AccessControlDefaultAdminRules`: a single admin, 2-step transfer, and a mandatory delay. A multisig is recommended. |
| **Malicious configuration** (for example minWindow = 0, huge minStake) | Every parameter has hard-coded bounds. Request parameters are snapshotted at creation. `unbondingPeriod` is snapshotted at `requestUnstake`. |
| **Permanent freeze via pause** | Pause blocks only *new* obligations (create, accept, register, deposit). Cancel, expire, all in-flight lifecycle steps, `withdraw` and `withdrawStake` are never pausable. |
| **Revoking all verifiers** | No funds are frozen: disputes time out and unreviewed completions close as refunds (tested; also `invariant_NoPermanentLock` with every verifier revoked). The effect is on fairness only: honest providers go unpaid if no verifier or buyer approves (R4-1). |

## Privacy

| Threat | Mitigation |
|---|---|
| **Medical data accidentally written onchain** | No `string` or `bytes` parameters in any external function or event (I9). The only free-form input is `bytes32`. The SDK (Phase 2+) will build hashes and never accept raw fields. A code-review checklist item is in the security review. |
| **Dictionary reversal of hashes** (for example hashing "malaria: positive") | Every person-related commitment is salted with 32 random bytes kept offchain (spec §5). Plain hashes of low-entropy data are prohibited. |
| **Metadata leakage via patterns** (service type + region + time + buyer could re-identify a patient in small populations) | Service types are generic catalog codes. `locationHash` is a coarse region, not an address. Buyers are businesses aggregating many patients. **Residual risk:** timing and volume analysis. Guidance: keep regions coarse and do not use per-patient buyer wallets. |
| **Provider private documents** | Only `metadataHash` goes onchain. Licences and KYC stay with the verifier offchain. |
| **Evidence leakage from the verifier's storage** | Out of chain scope. Evidence bundles are encrypted, and the verifier service must meet healthcare data-handling rules (Phase 3+). |
| **Permanence** | Onchain data cannot be deleted. The design assumes everything onchain is public forever. |

## Phase 3 additions (marketplace + escrow)

| Threat | Mitigation |
|---|---|
| **Provider claims another provider's job** | The accepting provider is always `msg.sender`. Directed requests accept only the named provider. Start and proof require `msg.sender == request.provider`. The escrow payee is bound once at acceptance, and the registry binds `requestId → provider` once. |
| **Marketplace (or a bug in it) closes provider A's job as provider B** | The registry rejects `recordJobClosed(id, B)` when the job is bound to A (`JobProviderMismatch`), and rejects double closes and re-binding (`JobNotOpen`, `JobAlreadyRecorded`). |
| **Settlement redirected to a different address** | `escrow.release(id)` takes no recipient. It pays only the payee bound at acceptance (payee ≠ payer, ≠ 0). `escrow.refund(id)` pays only the recorded payer. |
| **Marketplace bug over-reporting or under-reporting amounts** | The escrow moves the *stored* deposit amount. The marketplace checks the amount the escrow reports equals `price` (`EscrowAmountMismatch`, tested with mocked responses). |
| **Buyer tries to accept its own request / self-deal** | `BuyerCannotAccept` at creation (directed to self) and at acceptance. Sybil self-dealing with a second, verified provider wallet remains bounded by verification and stake (R-9). |
| **Proof-hash squatting** (copying another provider's commitment first so theirs reverts) | **Found and fixed in the Phase 3 review.** Replay protection is scoped per provider (now `ProofOfService.evidenceUsed[provider][commitment]`). Tested. |
| **Late dispute to stall a deterministic exit** | Disputes are only allowed before `serviceDeadline` (ACCEPTED/IN_SERVICE) or `reviewDeadline` (COMPLETED). Verifier rejection is only allowed before `reviewDeadline`. |
| **Buyer disappears after the provider finishes** | A verifier can approve the proof (T8), and the provider is paid. Without any review by `reviewDeadline`, T9 closes it as a no-fault refund, so the funds and the provider's stake are never locked. If the provider missed its deadline, the provider can expire the job itself (T15). |
| **Provider hoards open requests** (accepts and never serves) | The buyer's funds are locked until the `serviceDeadline` the buyer chose (6h to 30d after acceptance), then the buyer expires the job. The failure is visible on-chain (Phase 4 reputation). **Residual:** there is no stake slashing in the MVP (R3-2). Buyers can use directed requests. |
| **Reentrancy through a hook token** | `createRequest` is `nonReentrant`. All escrow mutators and withdrawals share one guard. Marketplace events come before module calls. Tested: re-creating during funding, and cancelling another request during a withdrawal. |
| **Pause used to force losses** | Only `createRequest` and `acceptRequest` are pausable. Every in-flight step and exit works while paused (tested; `invariant_NoPermanentLock` runs paused). |
| **Admin changes an in-flight request** | Price is immutable. Review and dispute periods are snapshotted per request (tested). There is no request setter. |
| **Front-running acceptance of open requests** | Arbitrum's FCFS sequencer has no public mempool or priority fees, so the first valid acceptance wins. Buyers who need a specific provider use directed requests. |

## Phase 4 additions (proof + reputation)

| Threat | Mitigation |
|---|---|
| **Unchallenged fake completion gets paid** (Phase 3 R3-3) | **Fixed.** Payment needs positive acceptance: buyer confirmation, verifier approval, or `PROVIDER_WINS` on a still-`SUBMITTED` proof. After `reviewDeadline`, an unreviewed completion is *refunded* (`closeUnreviewed`), not paid. Invariant: SETTLED ⇔ proof APPROVED or BUYER_ACCEPTED. |
| **Provider A submits proof for provider B's request** | The marketplace allows only the assigned provider (`msg.sender`). ProofOfService independently requires `provider == request.provider` (`ProviderMismatch`, tested with direct module calls). |
| **Proof replay across requests** | `proofHash` is computed onchain and bound to chain, PoS address, `requestId` and provider. Each `(provider, evidenceCommitment)` is single-use (`EvidenceAlreadyUsed`). The random-sequence fuzz reuses commitments constantly. |
| **Commitment squatting by another provider** | Replay scope is per provider, so a copied commitment produces a different `proofHash` and does not block the owner (tested). |
| **Proof overwrite or replacement** | One proof per request (`ProofAlreadySubmitted`). Terminal proof states are final (`ProofNotReviewable`). Invariant: a proof status never changes once terminal. |
| **Buyer or provider acting as verifier** | Checked twice: the marketplace (`ConflictOfInterest`) and PoS (`ConflictOfInterest`, and `NotVerifier` without the marketplace role). The invariant attack set includes a buyer and a provider that both hold `VERIFIER_ROLE`. |
| **Verifier approves after rejecting / rejected proof paid via dispute** | `REJECTED` is final. `PROVIDER_WINS` requires `SUBMITTED` (`ProofNotApprovable`). Tested, and covered by an invariant. |
| **ProofOfService used to trigger settlement** | PoS has no permission on the marketplace, escrow or registry. The marketplace calls PoS, never the other way round. PoS only reads marketplace state. |
| **Reputation double counting** | `outcomeRecorded[requestId]` makes it once per request. Invariant: outcome recorded ⇔ registry job CLOSED, and Σ `successfulJobs` == number of SETTLED requests. |
| **Reputation attributed to the wrong provider** | The provider comes from the registry's one-time acceptance binding and is cross-checked against the marketplace request (`ProviderMismatch`, tested via mocks). Invariant: counters equal the handler's independent record for the accepting provider. |
| **Marketplace injects arbitrary reputation facts** | Everything except the verifier's refund fault flag is derived from the marketplace, registry and PoS. The flag is validated against the status (`InvalidOutcome`: a SETTLED request cannot be a fault, an EXPIRED one always is). |
| **Admin edits or erases reputation or proofs** | Neither module has an admin, setters, reset or delete. |
| **Frivolous dispute damages a provider's record** | `REFUND_NO_FAULT` and timeouts never increment `failedJobs`. `disputes` is documented as a neutral involvement count. |
| **Dictionary attack on proof hashes** | Evidence commitments are salted offchain. The contract never receives or needs plaintext. |
| **Honest provider unpaid because nobody reviews** | **Residual (R4-1).** This is the deliberate trade-off for fixing R3-3. Mitigations: 7-day default review window, verifier SLAs, multiple verifiers, and the refund is recorded as no-fault. |


## Phase 5: whole-protocol threat model (2026-10-01)

> **Clinova does not claim fully trustless medical evidence verification.** Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion.

### Threat actors

| Actor | Capabilities assumed | Worst outcome found in Phase 5 |
|---|---|---|
| Malicious buyer | Any sequence of calls on its own requests; contract wallet with token hooks; frivolous disputes | Delays a provider's payment and, when **no verifier acts**, forces a no-fault refund of work that was done (R3-1 / R4-1). Cannot take escrow it is not owed. |
| Malicious provider | Any sequence of calls; copies public commitments; contract wallet with token hooks | When **no verifier acts**, can turn a missed deadline (fault) into a no-fault dispute timeout (R5-2). Cannot be paid without positive acceptance, cannot withdraw stake with an open job. |
| Outsider / attacker | Calls every external function; sends tokens directly to any contract | Nothing: every unauthorized call fails (authorization matrix, invariants). Direct transfers become inert surplus. |
| Malicious or compromised verifier | `VERIFIER_ROLE` on one or both contracts | Approves fake evidence or rejects genuine evidence for requests where it is not a party (R4-2). Can only pay the escrowed amount to the bound provider or refund the buyer. |
| Compromised admin key | `DEFAULT_ADMIN_ROLE` on registry and marketplace | Grants itself verifier roles, admits a sybil provider, takes **undirected OPEN** requests and approves its own fake proofs (R5-1, executable test). Cannot touch directed or already-accepted requests, stake, credits, request fields, proofs or reputation directly. |
| Token issuer (Circle) | Pause, blacklist, upgrade USDC | Freezes withdrawals (globally, or per address including the escrow itself). Lifecycle transitions continue; credits are preserved. |
| Arbitrum sequencer | Delay/reorder; timestamp skew (+1h/−24h) | Hours-scale windows absorb it; `block.number` is never used. |

### Trust assumptions

1. Marketplace verifiers are honest and live within `reviewPeriod` / `disputePeriod` (fairness, not fund safety, depends on this).
2. Registry verifiers admit only real, licensed providers (offchain KYC).
3. The admin is a multisig (recommended: behind a timelock so role grants are delayed and visible; this is deployment configuration, not a contract change).
4. The token is Circle USDC: correct ERC-20 semantics, 6 decimals. A token that reports success without moving funds is detected on every inflow but not on outflows (tested; documented).
5. Evidence bundles are encrypted, salted, and carry a manifest naming chain, ProofOfService address, request and provider, which the verifier checks (R5-3).

### Privileged roles

| Role | Where | Can | Cannot |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Registry, marketplace | Grant/revoke roles; bounded parameters for future requests/unstakes; 2-step delayed admin transfer | Move escrow or stake; edit requests, providers, proofs or reputation; settle or refund directly |
| `VERIFIER_ROLE` (registry) | Registry | Verify / revoke providers | Anything on the marketplace |
| `VERIFIER_ROLE` (marketplace) | Marketplace (read by PoS) | Approve / reject proofs, resolve disputes for non-party requests | Act on its own requests; pay any other address or amount |
| `PAUSER_ROLE` | Registry, marketplace | Block `register`, `depositStake`, `createRequest`, `acceptRequest` | Block any in-flight step, exit or withdrawal |
| Marketplace address | Escrow, registry, PoS, reputation | Per-request module writes (immutable; not grantable) | Arbitrary amounts or recipients; stake |

### Funds flow

```text
buyer --transferFrom(price)--> ClinovaEscrow  (locked per request; balance delta checked twice)
   release (positive acceptance only) --> credit[bound provider] --withdraw/withdrawTo--> provider or its chosen address
   refund  (cancel/expiry/close/timeout/verifier refund) --> credit[buyer] --withdraw/withdrawTo--> buyer
provider --transferFrom(stake)--> ProviderRegistry --withdrawStake (after unbonding, no open job)--> the same provider
direct transfers --> surplus in escrow/registry, or stranded in marketplace/PoS/reputation (never credited)
```

### State machines (one owner each; all independently defended)

- **Request** (marketplace): spec §1; every (state × action) pair is executed in `test/StateMachine.t.sol` against an explicit table.
- **Escrow** (escrow): NONE → FUNDED → (RELEASED | REFUNDED); payee bound once; driven directly as the marketplace in tests.
- **Proof** (ProofOfService): NONE → SUBMITTED → (APPROVED | REJECTED | BUYER_ACCEPTED | UNRESOLVED); final states immutable even for the marketplace.
- **Registry job**: NONE → OPEN → CLOSED, bound to one provider; never reopens.

### Pause and dispute behaviour

- Pause blocks only new obligations (`createRequest`, `acceptRequest`, `register`, `depositStake`). Tested at every lifecycle stage with both contracts paused (`test/Liveness.t.sol`): cancel, expiry, start, proof, confirm, approve/reject, dispute, resolve, timeout, unreviewed close, escrow withdrawal, unstake and stake withdrawal all work while paused.
- A dispute ends by verifier resolution (any time until the timeout executes) or by `resolveDisputeByTimeout` after `disputeDeadline` (anyone; no-fault refund). A rejected proof is final and can never be paid.

### Phase 5 residual risks (see security-review.md for the full list)

| ID | Risk | Classification |
|---|---|---|
| R5-1 | Compromised admin can self-grant verifier roles and pay a sybil provider for undirected OPEN requests | Trust assumption (centralization). Mitigate with multisig + timelock admin, RoleGranted monitoring, directed requests for high value. |
| R5-2 | Without a live verifier, a provider can dispute before its deadline to avoid a `failedJobs` mark (buyer refund delayed by ≤ `disputePeriod`) | Deliberate trade-off (dispute timeout is no-fault); same root as R3-1. |
| R5-3 | Raw evidence commitments are single-use per deployment only | Offchain requirement: bundle manifest checked by the verifier. |
| R5-4 | Circle can freeze the escrow's own USDC | External trust assumption; credits preserved. |
