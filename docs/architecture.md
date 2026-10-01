# Clinova Architecture

> Clinova turns distributed healthcare diagnostic capacity into programmable infrastructure.

Status: **Phase 5 (security hardening complete; not deployed).** All five contracts are implemented and tested. The exact behavior is in [contract-spec.md](contract-spec.md).

> **Security statement.** Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion. The blockchain does **not** prove that a medical service physically happened.

## 1. System overview

```text
                ┌───────────────────────── OFFCHAIN ──────────────────────────┐
 Healthcare     │  Buyer backend / agent        Provider ops         Verifier   │
 business ──────┤  (patient identity, orders)   (sample, results)    service    │
 (buyer)        │          │                          │                 │       │
                └──────────┼──────────────────────────┼─────────────────┼───────┘
                           │ tx: ids, hashes, USDC    │ tx: proofHash   │ tx: verdicts
                ┌──────────▼──────────────────────────▼─────────────────▼───────┐
                │                    ARBITRUM SEPOLIA                            │
                │                                                                │
                │   ServiceMarketplace  (state machine; the only orchestrator)   │
                │      │  hooks: onlyMarketplace (immutable address)             │
                │      ├──► ClinovaEscrow        USDC payment custody            │
                │      ├──► ProofOfService       proof commitments               │
                │      ├──► ReputationRegistry   counters                        │
                │      └──► ProviderRegistry     reads eligibility; active-job   │
                │                                count (USDC stake custody)      │
                └────────────────────────────────────────────────────────────────┘
```

### Design principles

1. **One orchestrator.** `ServiceMarketplace` owns the request state machine. Every request state transition starts there. The other contracts are single-purpose modules.
2. **Single writer per module.** Escrow, ProofOfService and ReputationRegistry accept writes only from the marketplace address. That address is fixed at deployment (`immutable`). It is not a grantable role, so an admin cannot grant itself write access to escrow.
3. **Separated custody.** Payment escrow (in `ClinovaEscrow`) and provider stake (in `ProviderRegistry`) are held in different contracts. Each has its own conservation invariant.
4. **Pull payments.** Settlement and refunds credit an internal balance, and recipients call `withdraw()`. A USDC blacklist or a reverting recipient cannot block settlement for anyone else.
5. **Minimal admin.** The admin manages roles, pause, and parameters for *future* requests. The admin has no function that moves user funds.
6. **Hashes, not data.** Only identifiers, amounts, timestamps and salted commitments go onchain.

## 2. Actors

| Actor | Onchain identity | Can | Cannot |
|---|---|---|---|
| **Provider** (lab, diagnostic centre, collection centre) | Its wallet (`msg.sender`). No ownership transfer. | Register, stake, publish services, accept requests (always as itself), start service, submit proof, dispute before the deadline, expire its own missed job (the refund goes to the buyer), withdraw earnings, unbond stake | Accept without being verified, active, staked and capable; act on another provider's request; submit a proof twice; dispute its own completed job |
| **Buyer** (telemedicine, hospital, HMO, platform, AI agent) | Its wallet, which may be a smart account | Create and fund requests (atomically), direct a request to one provider, cancel while OPEN, confirm completion, dispute (before the service deadline, or within the review window), expire after a missed deadline, withdraw refunds | Cancel after acceptance; refund itself before a deadline without a dispute; change price after creation; settle someone else's request |
| **Verifier** | `VERIFIER_ROLE`, granted separately on the registry and the marketplace | Verify providers, approve or reject completions, resolve disputes (including after the dispute deadline, until the timeout is executed) | Act on requests where it is the buyer or provider; pay any amount other than the escrowed amount; pay anyone other than the request's bound provider or its buyer |
| **Admin** | `DEFAULT_ADMIN_ROLE`, via `AccessControlDefaultAdminRules` with a 2-step, delayed transfer and a multisig recommended | Grant and revoke roles; set parameters (these apply only to new requests); pause | Move escrow or stake; settle or refund; edit requests; change provider ownership; mark services complete |
| **Pauser** | `PAUSER_ROLE` | Pause or unpause *new* activity (`createRequest`, `acceptRequest`, `register`, `depositStake`) | Block any in-flight step, refund, expiry, settlement, timeout or withdrawal |
| **Anyone** | any address | Expire an OPEN request after its accept deadline, close an unreviewed completion after the review window (refund, no fault), execute a dispute timeout | Receive anything: these exits pay only the request's buyer or bound provider, and **never pay a provider** |

## 3. Contracts

| Contract | Responsibility | Holds funds? | Written by |
|---|---|---|---|
| `ProviderRegistry` | Provider records (`metadataHash`, `locationHash` region code), offered service types, USDC stake, verified and active flags, per-request job binding and active-job counter, stake unbonding | **Yes: stake** | Provider (self), verifier (verify flag), marketplace (open or close the exact `(requestId, provider)` job) |
| `ServiceMarketplace` | Request creation, provider selection and acceptance, lifecycle state machine, deadlines, disputes. Calls the other modules. | No | Buyer, provider, verifier, anyone for expiry |
| `ClinovaEscrow` | Per-request deposit with its own state machine (NONE → FUNDED → RELEASED or REFUNDED); payee bound once at acceptance; pull-payment credits. No admin, no pause, no rescue. | **Yes: payments** | Marketplace only, per request ID; users can only withdraw their own credit |
| `ProofOfService` | Source of truth for completion proofs. Stores the provider's salted evidence commitment, an **onchain-computed** `proofHash` bound to chain, contract, request and provider, and the review outcome: `SUBMITTED` → `APPROVED`, `REJECTED`, `BUYER_ACCEPTED` or `UNRESOLVED`. One proof per request; commitments single-use per provider. Re-checks provider, buyer and verifier independence against the marketplace. | No | Marketplace only; no permission on any other module |
| `ReputationRegistry` | Objective counters `completedJobs`, `successfulJobs`, `failedJobs` and `disputes` per provider. One record per finished accepted request. The provider comes from the registry's acceptance binding, and outcome facts are read from the marketplace, registry and PoS. No admin, no setters. | No | Marketplace only, once per request |

**Overlap check.**

- Request state lives only in the Marketplace.
- Payment custody lives only in Escrow. Stake custody lives only in the Registry.
- Proof data lives only in ProofOfService, and reputation only in ReputationRegistry.
- Each contract has exactly one writer for each piece of state.
- ProofOfService and ReputationRegistry could technically be merged into the Marketplace. They are kept separate on purpose: they are the parts a third party (a buyer's system, or a future protocol) would read or reuse on its own, and separation keeps the Marketplace under the contract size limit.

**Deployment wiring (implemented: `contracts/script/Deploy.s.sol`).**

- Deployment order is registry (deployer nonce n), escrow (n+1), ProofOfService (n+2), ReputationRegistry (n+3), then marketplace (n+4).
- The four modules take the **precomputed** marketplace address as an `immutable` constructor argument.
- The marketplace constructor **reverts** (`InvalidWiring`) unless all four modules name it as their marketplace, the registry and escrow use the same token, and reputation reads the same registry and ProofOfService. The script asserts that the predicted address matches and then runs `verify()`, which re-checks every reference, the token (Circle USDC on chain 421614), admin, roles and parameters (Phase 5).
- The prediction assumes nothing else uses the deployer's nonce during the deployment. If it does, deployment fails closed (see `script/Deploy.s.sol`). Use a fresh deployer key.
- There are no mutable one-time setters.
- Roles (`VERIFIER_ROLE`, `PAUSER_ROLE` on the registry and the marketplace) are granted afterwards by the admin.
- **In production, the admin must be a multisig** (for example a Safe). Admin transfer is 2-step with a delay (`AccessControlDefaultAdminRules`).
- The integration tests deploy through the same script.

## 4. Core flow

The buyer approves the **marketplace** for `price`. `createRequest` then moves USDC buyer → escrow directly. The marketplace never holds funds, and the escrow independently checks that the tokens arrived before recording the deposit.

```text
Buyer                       Marketplace                 Escrow        Provider        Verifier
  │ createRequest(+USDC) ─────►│ OPEN ───── lock ───────►│
  │                            │◄──────────── acceptRequest ───────────│
  │                            │ ACCEPTED                              │
  │                            │◄──────────── startService ────────────│ (sample collected)
  │                            │ IN_SERVICE                            │
  │                            │◄──────────── submitProof(hash) ───────│
  │                            │ COMPLETED  (proof recorded)
  │ confirmCompletion ────────►│  or  ◄────────────────── approveProof ─────────────────│
  │                            │  (no review by reviewDeadline → anyone: closeUnreviewed → refund, no fault)
  │                            │ SETTLED ── release ────►│ credit bound payee
  │                            │                         │◄── withdraw ── provider
```

Alternative paths are specified in [contract-spec.md](contract-spec.md) §1:

- cancel;
- expire, callable by the buyer or the provider after a missed deadline;
- dispute, then verifier resolution;
- dispute timeout, which refunds the buyer with no fault recorded.

**Payment rule (Phase 4):** a provider is paid only after **positive acceptance**. That means the buyer confirms, a non-party verifier approves the proof, or a verifier resolves a dispute for the provider while the proof is still under review. A completion nobody reviews before `reviewDeadline` is refunded as *unresolved*, with no fault recorded. A proof a verifier rejected can never lead to payment.

**Module boundaries:**

- **ProviderRegistry:** identity, stake, eligibility, active jobs.
- **ServiceMarketplace:** request lifecycle, and the single entry point for all users.
- **ClinovaEscrow:** funds.
- **ProofOfService:** proof lifecycle.
- **ReputationRegistry:** history.

Every cross-module permission is a per-request call from the marketplace's immutable address. ProofOfService and ReputationRegistry hold no permission on any other module, so neither can settle, refund or move funds.

**Liveness guarantee (invariant-tested):** from any state, with no verifier, no admin, and the marketplace paused, every request reaches a terminal state and every credit can be withdrawn. The longest possible wait is bounded by deadlines fixed at creation. The worst case, using the maximum admin bounds, is 7 days (accept) + 30 days (service) + 14 days (review) + 60 days (dispute) = **111 days**. With the deploy-script defaults it is 7 + 30 + 7 + 14 = 58 days.

## 5. Onchain / offchain boundary

### ONCHAIN (public, permanent)

| Data | Form |
|---|---|
| Wallet addresses | `address` (buyer = business, not patient) |
| Provider ID | Provider wallet address |
| Service request ID | `uint256` sequential |
| Service type | `bytes32` catalog code, e.g. `keccak256("LAB.CBC.V1")`. This is a public catalog code, not patient data. |
| Price / escrow amount | `uint256` USDC base units |
| Request status | `enum` |
| Timestamps / deadlines | `uint64` |
| Proof hash | `bytes32` **salted** commitment to an offchain evidence bundle |
| Provider metadata / region | `bytes32` hashes of offchain documents and a **coarse region code** |
| Provider stake | `uint256` |
| Reputation statistics | `uint64` counters |

### OFFCHAIN (never onchain, not even hashed without a salt)

Patient identity, contact information, medical history, diagnosis, test results, medical documents, exact patient location, detailed and private provider documents (licences, KYC), and private evidence (photos, chain-of-custody forms, device logs).

### Privacy rules

1. **No patient reference of any kind onchain.** Requests are between businesses. The mapping from `requestId` to patient exists only in the buyer's own systems.
2. **Hashes are not encryption.** A plain `keccak256` of a low-entropy value (a test result, a phone number, a street address) can be reversed by dictionary. Every hash that could relate to a person must be salted with a random 32-byte `salt` kept offchain. For proofs the exact construction is in spec §5; the evidence bundle must also carry a manifest naming chain, ProofOfService address, request and provider, which the verifier checks (Phase 5, R5-3).
3. **Proof hash = commitment to an encrypted evidence bundle** that the verifier holds. The chain proves *that* evidence existed at time T and was not later altered. It says nothing about *what* the evidence is.
4. **`locationHash` is a coarse service region** (for example a city or zone code), used for matching. It is never a patient address. Region codes are treated as effectively public.
5. **Events mirror storage.** Events contain only the fields above: no strings and no free text. There is no `string` parameter anywhere in the external API. This removes the most likely way medical text could leak onchain.
6. **Metadata** (`metadataHash`) points to provider-published business information stored offchain. It is published business information, not private documents.
7. Onchain data is permanent. Anything that would be a problem if it were public forever must stay offchain.

## 6. Proof of service: what it does and does not prove

```text
Physical service → offchain evidence (encrypted) → verifier review → salted hash → Arbitrum
```

- **Proves:** the provider committed to a specific evidence bundle at a specific time for a specific request, and a named verifier (or the paying buyer) accepted it. The commitment cannot be altered or reused for another request.
- **Does not prove:** that the test was physically and correctly performed. That rests on the verifier's review and the provider's stake and reputation. **The MVP is not trustless medical verification.** The verifier is an explicit trust assumption.

## 7. Staking (MVP)

- A provider must hold `stake >= minStake` (USDC) to accept requests. If the admin changes `minStake` (within hard-coded bounds), only eligibility for *new* acceptances is affected. Existing stake and in-flight jobs are never touched.
- **Unstaking:** `requestUnstake()` deactivates the provider. After `unbondingPeriod` has passed *and* `activeJobs == 0`, `withdrawStake()` returns the **full** stake to the provider's own address.
- **No slashing in the MVP.** Stake cannot leave the registry except to its owner. Possible future slashing conditions:
  - a provider accepts and then fails to deliver (dispute resolved against them);
  - a fraudulent proof is shown via evidence;
  - repeated SLA breaches.

  Any slashing would need a dispute process, a cap, and a timelock. It is out of scope and must not be added ad hoc.

## 8. Trust assumptions

1. **Registry verifiers are honest.** They decide which providers are verified, based on offchain KYC and licences. A dishonest verifier could admit a bad provider. That provider's stake and public track record are then at risk, but no funds can move to anyone who is not a party.
2. **Dispute verifiers are honest.** They can approve a fraudulent completion or wrongly refund. Mitigations:
   - powers are role-scoped;
   - a verifier cannot act on its own requests;
   - it can only pay the escrowed amount to the bound provider or the buyer;
   - every decision is a public event.
3. **Verifier liveness is *not* required for funds, but since Phase 4 it matters for honest providers.** If verifiers are absent:
   - an unreviewed completion is refunded to the buyer after the review window (never paid);
   - a dispute times out to a no-fault refund;
   - a missed deadline expires.

   The cost of verifier absence is *fairness*, not locked funds. For example, a buyer's frivolous dispute returns the money to the buyer if nobody resolves it.

   Since Phase 4, an honest provider whose buyer does not confirm is paid only if a verifier approves the proof before `reviewDeadline` (7 days by default). Verifier SLAs must be shorter than the review period. Phase 4 chose this trade-off on purpose: an unreviewed claim is refunded rather than paid.
4. **Admin (multisig) is honest.** It can pause new activity, change bounded parameters for future requests, and grant or revoke roles, including granting itself `VERIFIER_ROLE` (a residual risk). It has no function that moves escrow or stake, or that edits an existing request.
5. **Circle USDC.** Circle can pause or blacklist the token or upgrade it. Pull payments limit the damage to the affected address, and `withdrawTo` lets a blocked account withdraw its credit to a different address. The token address is injected at deployment, and 6 decimals are checked.
6. **Arbitrum sequencer.** It can delay but not forge transactions. Deadlines are hours-scale (accept window at least 1h, service window at least 6h, review at least 1 day, dispute at least 3 days), so sequencer timestamp skew (up to +1h or −24h) and outages matter little. Force-inclusion is available after ~24h. `block.number` is never used.
7. **Offchain healthcare evidence** is outside the chain's guarantees: its storage, confidentiality, and authenticity (whether the lab, the sample and the results are genuine). The chain proves who committed to what, how much was locked, which provider accepted, which transitions happened and whether settlement or refund occurred. **It does not prove that a diagnostic service physically happened.**

## 9. Account abstraction compatibility

Contracts must never use `tx.origin`, must not reject contract callers, and must authenticate only by `msg.sender`. This keeps buyer AI agents and ZeroDev/ERC-4337 smart accounts working later with no contract changes.
