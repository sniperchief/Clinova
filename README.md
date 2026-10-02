# Clinova

> **The real-world healthcare infrastructure layer for telemedicine.** Clinova is a DePIN/RWA infrastructure network that connects telemedicine platforms and healthcare applications to verified real-world diagnostic capacity, turning that capacity into programmable infrastructure.

**Status: Phase 7 (web app) complete, awaiting review.** All five contracts (`ProviderRegistry`, `ServiceMarketplace`, `ClinovaEscrow`, `ProofOfService`, `ReputationRegistry`) are implemented and tested: 414 tests (unit, scenario, fuzz, three invariant campaigns) plus 7 Arbitrum Sepolia fork tests against real Circle USDC; Slither and Aderyn reviewed. They are **not externally audited** and are **deployed on Arbitrum Sepolia testnet only** (see below). A web app for buyers, providers and verifiers runs against the deployed contracts (see [Web app](#web-app)). See [docs/security-review.md](docs/security-review.md) for findings and remaining risks.

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
- **RWA framing:** the real-world asset is healthcare *capacity* (laboratories, diagnostic equipment, testing availability) made discoverable, reservable and payable onchain. Clinova does not tokenize ownership of labs or equipment, and it does not tokenize patient data or medical records.

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
apps/web/                 web app: Vite + React + wagmi/viem (Phase 7)
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

## Arbitrum Sepolia Deployment

Deployed on 2026-10-01 from commit `35ba3a6`. All five contracts are **verified on Arbiscan** (solc 0.8.30, optimizer 200 runs, EVM cancun). Full record with transaction hashes, checks and the live test results: [docs/deployment-arbitrum-sepolia.md](docs/deployment-arbitrum-sepolia.md).

| | |
|---|---|
| Chain | Arbitrum Sepolia, chain ID `421614` |
| ProviderRegistry | [`0x8f6817E251cb23DaF5EcC064A4380B03D20E37ed`](https://sepolia.arbiscan.io/address/0x8f6817E251cb23DaF5EcC064A4380B03D20E37ed#code) |
| ServiceMarketplace | [`0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0`](https://sepolia.arbiscan.io/address/0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0#code) |
| ClinovaEscrow | [`0xcc66A42934450a67439cD7B999C3270C6BafFdef`](https://sepolia.arbiscan.io/address/0xcc66A42934450a67439cD7B999C3270C6BafFdef#code) |
| ProofOfService | [`0xcFe3c6D4Ab8c0487e04686B182D24dD23041a436`](https://sepolia.arbiscan.io/address/0xcFe3c6D4Ab8c0487e04686B182D24dD23041a436#code) |
| ReputationRegistry | [`0xdab85e7Df2bEaA2E7dD455a3e86d628784B9329a`](https://sepolia.arbiscan.io/address/0xdab85e7Df2bEaA2E7dD455a3e86d628784B9329a#code) |
| USDC (Circle) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Admin | `0xB4B8B6CD7C7adB5c68472A8092d2f7f747BF83C5` (temporary testnet EOA; to move to a multisig) |

A real end-to-end flow with Circle USDC (register, stake, verify, request, escrow, accept, proof, verifier approval, settlement, withdrawal, reputation) plus dispute, cancel-refund, pause/unpause and access-control checks ran against these contracts; see the deployment record.

**Interacting** (read-only examples; anyone can run them):

```bash
RPC=https://sepolia-rollup.arbitrum.io/rpc
MKT=0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0
cast call $MKT "nextRequestId()(uint256)" --rpc-url $RPC
cast call $MKT "getRequest(uint256)((address,uint64,uint8,uint8,address,uint64,bytes32,bytes32,uint128,uint64,uint32,uint32,uint64,uint64))" 1 --rpc-url $RPC
cast call 0xdab85e7Df2bEaA2E7dD455a3e86d628784B9329a "getReputation(address)((uint64,uint64,uint64,uint64))" <provider> --rpc-url $RPC
```

Buyers approve the **marketplace** for the price, then call `createRequest` (funding is atomic). Providers approve the **registry** for the stake, then `register`; verification is granted by a `VERIFIER_ROLE` holder. See [docs/contract-spec.md](docs/contract-spec.md) for every function.

## Web app

```bash
cd apps/web && npm install && npm run dev     # http://localhost:5173
```

Connect a browser wallet on Arbitrum Sepolia (chain `421614`) with test ETH and Circle test USDC. Buyers discover providers, create and fund requests, confirm or dispute; providers register, stake, get verified, accept jobs, submit salted proof commitments and withdraw earnings; verifiers verify providers, review proofs and resolve disputes. All protocol state is read from the contracts and every step links to Arbiscan. Evidence never leaves the provider's device; only a salted commitment goes onchain. Details and test commands: [docs/frontend.md](docs/frontend.md).

## Testnet plan

| Item | Value |
|---|---|
| Network | Arbitrum Sepolia, chain ID `421614` |
| RPC | `ARB_SEPOLIA_RPC_URL` (public: `https://sepolia-rollup.arbitrum.io/rpc`) |
| Explorer | https://sepolia.arbiscan.io |
| Gas | Sepolia ETH from arbitrum.faucet.dev, QuickNode or L2Faucet (no bridging needed) |
| USDC | Circle testnet USDC via faucet.circle.com; the address comes from `USDC_ADDRESS` |

Phase 6 deployed the five contracts with `forge script ... --verify` and ran the end-to-end flow on Arbitrum Sepolia (see [Arbitrum Sepolia Deployment](#arbitrum-sepolia-deployment)).

## Phases

1. Architecture, research and foundation. ✅
2. ProviderRegistry implementation and testing. ✅
3. ServiceMarketplace + ClinovaEscrow, registry integration, deploy script. ✅
4. ProofOfService + ReputationRegistry; payment requires positive acceptance. ✅
5. Full-protocol security, fuzzing, invariants and fork testing. ✅
6. Arbitrum Sepolia deployment, contract verification and a real testnet end-to-end flow. ✅
7. **Web app, wallet integration and interaction with the deployed contracts.** ✅ ← current (awaiting review)
8. Verification service and SDK.
