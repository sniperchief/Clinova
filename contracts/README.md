# Clinova contracts

This is a Foundry project. Solidity 0.8.30 with EVM `cancun`, OpenZeppelin Contracts v5.7.0, and forge-std v1.17.0.

**Phase 5:** all five contracts are implemented and security-hardened. Everything follows [docs/contract-spec.md](../docs/contract-spec.md); findings are in [docs/security-review.md](../docs/security-review.md).

```text
src/libraries/ClinovaTypes.sol     enums/structs (Status, ServiceRequest, Provider, ServiceProof, Reputation)
src/interfaces/I*.sol              the five contract interfaces (events, errors, functions)
src/ProviderRegistry.sol           provider records, capabilities, USDC stake, verification, per-request job binding
src/ServiceMarketplace.sol         request state machine (fixed price, deadlines, disputes + timeout)
src/ClinovaEscrow.sol              per-request USDC escrow, pull payments, no admin
src/ProofOfService.sol             proof commitments (onchain-bound hash), review lifecycle, no admin
src/ReputationRegistry.sol         objective per-provider outcome counters, once per request, no admin
script/Deploy.s.sol                wired deployment (precomputed marketplace address) + post-deploy verify()
test/ServiceMarketplace.t.sol, ClinovaEscrow.t.sol, ProofOfService.t.sol, ReputationRegistry.t.sol,
     Integration.t.sol, Clinova.{fuzz,invariant}.t.sol
test/ProviderRegistry*.t.sol       unit, fuzz and invariant suites (mocks in test/mocks/)
test/Foundation.t.sol              type checks + optional Arbitrum Sepolia USDC fork check
test/Clinova.system.invariant.t.sol  Phase 5 whole-protocol invariants (incl. provider lifecycle, roles, pause)
test/StateMachine.t.sol, AuthorizationMatrix.t.sol, Adversarial.t.sol, Liveness.t.sol,
     MaliciousToken.t.sol, BoundariesAndReplay.t.sol, DeployScript.t.sol    Phase 5 security suites
test/fork/ArbitrumSepolia.fork.t.sol  full flow against real Circle USDC on an Arbitrum Sepolia fork
```

```bash
forge build
forge test -vv
ARB_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc forge test --mt test_Fork -vv   # fork tests (optional FORK_BLOCK)
```
