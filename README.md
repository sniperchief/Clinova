# Clinova

> Clinova turns distributed healthcare diagnostic capacity into programmable infrastructure.

**Status: Phase 5 (security hardening) complete.** All five contracts (`ProviderRegistry`, `ServiceMarketplace`, `ClinovaEscrow`, `ProofOfService`, `ReputationRegistry`) are implemented and tested: 414 tests (unit, scenario, fuzz, three invariant campaigns) plus 7 Arbitrum Sepolia fork tests against real Circle USDC; Slither and Aderyn reviewed. They are **not externally audited** and **not yet deployed**. There is no frontend yet. See [docs/security-review.md](docs/security-review.md) for findings and remaining risks.

> Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion. It does not claim that the blockchain proves a medical service happened.

## Problem

Healthcare businesses such as telemedicine companies, HMOs, hospitals, platforms and AI agents need basic lab diagnostics (CBC, malaria, blood glucose, lipid profile) wherever their patients are. That capacity is spread across thousands of independent labs and collection centres. Today, reaching them means bilateral contracts, manual coordination, slow reconciliation, and no shared, verifiable record of who delivered what, when, or how reliably.

## Solution

Clinova is a **B2B network** in which diagnostic capacity can be discovered, reserved and paid for programmatically:

```text
Discover → Reserve → Escrow USDC → Service performed → Proof submitted → Proof verified → Settled → Reputation updated
```

Buyers fund a request in USDC escrow. A staked, verified provider accepts and performs the service, then commits a salted hash of the offchain evidence. After verification or buyer confirmation, payment settles and the provider's public track record updates.

## DePIN model

- **Physical infrastructure:** labs, diagnostic centres and sample-collection points.
- **Network layer (onchain):** provider registry and stake, request state machine, escrow, proof commitments, reputation.
- **Incentives:** providers earn USDC per verified job. Stake and public reputation make reliable capacity more valuable than unreliable capacity.
- **No token.** Payments are in USDC. Clinova coordinates real-world capacity; it does not issue a speculative asset.

## Why Arbitrum

- Many small lifecycle transactions per test are only practical at L2 fees. Observed Sepolia gas price was about 0.03 gwei.
- Full EVM equivalence: Solidity, Foundry and OpenZeppelin work unchanged.
- Native Circle USDC is available.
- Ethereum-anchored security for escrowed funds.
- Sub-second soft confirmations for an operational UX.

See [docs/arbitrum-research.md](docs/arbitrum-research.md).

## Architecture

| Contract | Role |
|---|---|
| `ProviderRegistry` | Provider records (hashes only), services offered, USDC stake, verification |
| `ServiceMarketplace` | Request lifecycle state machine; the single orchestrator |
| `ClinovaEscrow` | USDC custody per request; pull-payment settlement and refunds |
| `ProofOfService` | Salted, replay-protected proof-of-service commitments |
| `ReputationRegistry` | Completed, successful, failed and disputed counters |

**Actors:** provider, buyer (healthcare business), verifier (a trusted role in the MVP), and admin. The admin has **no** access to funds.

**Patient data never goes onchain.** Only IDs, amounts, statuses, timestamps and salted commitments do.

Docs:

- [Architecture and privacy boundary](docs/architecture.md)
- [Contract spec and state machine](docs/contract-spec.md)
- [Threat model](docs/threat-model.md)
- [Security review log](docs/security-review.md)

## Repository

```text
apps/web/                 frontend (Phase 3+)
contracts/                Foundry project: src/interfaces, src/libraries, test, script
services/verification/    offchain verifier service (later phase)
packages/sdk, types/      TypeScript SDK and shared types (later phase)
docs/                     architecture, spec, threat model, research
```

## Development setup

Requirements: Git, and Foundry ≥ 1.8 (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).

```bash
git clone --recurse-submodules <repo>    # or: git submodule update --init --recursive
cp .env.example .env                     # fill in values; never commit .env
cd contracts
forge build
forge test -vv
# fork tests against real Arbitrum Sepolia USDC (skipped when ARB_SEPOLIA_RPC_URL is unset):
set -a; source ../.env; set +a; forge test --mt test_Fork -vv
```

Pinned versions: Solidity 0.8.30 (EVM `cancun`), OpenZeppelin Contracts v5.7.0, and forge-std v1.17.0.

## Testnet plan

| Item | Value |
|---|---|
| Network | Arbitrum Sepolia, chain ID `421614` |
| RPC | `ARB_SEPOLIA_RPC_URL` (public: `https://sepolia-rollup.arbitrum.io/rpc`) |
| Explorer | https://sepolia.arbiscan.io |
| Gas | Sepolia ETH from arbitrum.faucet.dev, QuickNode or L2Faucet (no bridging needed) |
| USDC | Circle testnet USDC via faucet.circle.com; the address comes from `USDC_ADDRESS` |

Phase 6 deploys the five contracts with `forge script ... --verify` and runs a scripted end-to-end demo (register → stake → verify → request → accept → proof → settle) to produce visible onchain activity.

## Phases

1. Architecture, research and foundation. ✅
2. ProviderRegistry implementation and testing. ✅
3. ServiceMarketplace + ClinovaEscrow, registry integration, deploy script. ✅
4. ProofOfService + ReputationRegistry; payment requires positive acceptance. ✅
5. **Full-protocol security, fuzzing, invariants and fork testing.** ✅ ← current (awaiting review)
6. Arbitrum Sepolia deployment, contract verification and a real testnet end-to-end flow.
7. Verification service and SDK.
8. Web app.
