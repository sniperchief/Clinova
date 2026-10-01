# Arbitrum Research Notes

Research done 2026-09-30 against the live official docs, plus direct RPC queries. Where a doc disagreed with the Phase 1 brief, the doc was followed. Those cases are marked **⚠ Deviation**.

## Sources consulted

| Resource | URL | Status |
|---|---|---|
| Get Started | `docs.arbitrum.io/welcome/get-started` | **404**. The page now lives at `/get-started/arbitrum-introduction` |
| Gentle Introduction | `docs.arbitrum.io/welcome/arbitrum-gentle-introduction` | OK |
| Solidity Quickstart | `docs.arbitrum.io/build-decentralized-apps/quickstart-solidity-remix` | OK |
| Bridge Quickstart | `docs.arbitrum.io/arbitrum-bridge/quickstart` | OK |
| Oracles content map | `docs.arbitrum.io/for-devs/oracles/oracles-content-map` | OK |
| FAQ | `docs.arbitrum.io/learn-more/faq` | OK |
| Chain info (RPC, explorers, params) | `docs.arbitrum.io/for-devs/dev-tools-and-resources/chain-info` | OK |
| Arbitrum vs Ethereum overview | `docs.arbitrum.io/build-decentralized-apps/arbitrum-vs-ethereum/comparison-overview` | OK |
| Block numbers and time | `.../arbitrum-vs-ethereum/block-numbers-and-time` | OK |
| Solidity support differences | `.../arbitrum-vs-ethereum/solidity-support` | OK |
| How to estimate gas | `docs.arbitrum.io/build-decentralized-apps/how-to-estimate-gas` | OK |
| Stylus gentle introduction | `docs.arbitrum.io/stylus/gentle-introduction` | OK |
| Robinhood Chain | `docs.robinhood.com/chain/` | OK |
| ZeroDev | `docs.zerodev.app/` | OK (landing page) |
| Circle USDC addresses | `developers.circle.com/stablecoins/usdc-contract-addresses` | OK |
| OpenZeppelin Contracts releases | GitHub API | Latest release is `v5.7.0` (2026-07-29) |
| Foundry releases | GitHub API | Latest release is `v1.8.3` (2026-09-15) |

## Network: Arbitrum Sepolia

| Item | Value | Verified by |
|---|---|---|
| Chain ID | `421614` | Docs, and `eth_chainId` returned `0x66eee` |
| Public RPC | `https://sepolia-rollup.arbitrum.io/rpc` | Chain-info and bridge docs, plus a live query |
| Sequencer endpoint | `https://sepolia-rollup-sequencer.arbitrum.io/rpc` (send-only) | Chain-info docs |
| Explorers | `https://sepolia.arbiscan.io`, `https://arbitrum-sepolia.blockscout.com` | Chain-info docs |
| Native gas token | ETH (the docs call it "SepoliaETH") | Bridge docs |
| Parent chain | Ethereum Sepolia | Chain-info docs |
| Dispute window | 20 blocks (~4 min) on Sepolia, ~6.4 days on One | Chain-info docs |

The public RPC is rate-limited. For deployment and demos, set `ARB_SEPOLIA_RPC_URL` to a provider endpoint (Alchemy, Infura, QuickNode and others are listed in the docs). **Credentials go only in `.env` and are never committed.**

### Testnet USDC

- Circle's official Arbitrum Sepolia USDC is `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`.
- On-chain check (`eth_call`): `name()` returns "USD Coin", `symbol()` returns "USDC", and `decimals()` returns **6**. Bytecode is present, and it is an upgradeable proxy (`implementation()` selector).
- Get test funds from `faucet.circle.com`, selecting Arbitrum Sepolia.
- The address is loaded only from `USDC_ADDRESS` and is never hardcoded in contracts. Contracts take the token as a constructor argument and store it as `immutable`.
- **Design implications of USDC (FiatToken):**
  - It has **6 decimals**, so all amounts are in base units (1 USDC = `1_000_000`).
  - Circle can **pause** the token or **blacklist** addresses. A push-payment to a blacklisted provider would revert and could trap escrow. Clinova therefore uses **pull payments**: settlement credits a balance, and the recipient later calls `withdraw()`.
  - The token is upgradeable. Its behavior could change, which is an external trust assumption.
- Arbitrum *One* has both native and bridged USDC (per the bridge docs). A mainnet deployment must use native USDC. This does not affect Sepolia.

## Solidity

- The docs say Arbitrum is EVM-equivalent and Solidity deploys "just like on Ethereum", with a short list of opcode differences (see below).
- Clinova's logic consists of state machines, access checks and ERC-20 accounting. It has no compute-heavy work. Solidity has the most mature audit and tooling ecosystem for this kind of code, and OpenZeppelin 5.x is Solidity-native.
- Compiler: `0.8.30`, which OZ 5.7 accepts. `evm_version = "cancun"` is pinned explicitly so Foundry's newer defaults cannot emit opcodes the target chain may not support.

## Foundry workflow

The Arbitrum Solidity quickstart itself names Foundry as its toolchain ("Foundry is the toolchain we'll use to compile and deploy", with `anvil` as the local chain).

```text
forge build                          # compile
forge test -vvv                      # unit + fuzz + invariant tests (local EVM)
forge test --fork-url $ARB_SEPOLIA_RPC_URL   # fork tests against real USDC
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --broadcast --verify
```

- Unit tests use a mock 6-decimal ERC-20. Fork tests use real Sepolia USDC.
- Invariant tests (Phase 2) cover escrow conservation and the absence of double settlement.
- Deploy with a Foundry keystore (`cast wallet import`) in preference to a raw `PRIVATE_KEY`.
- Verification goes through the Etherscan-family API (`ARBISCAN_API_KEY`). Recent Foundry uses the Etherscan V2 multichain API, so an Etherscan.io key is expected to work for chain 421614. This is confirmed at first deploy.

## OpenZeppelin primitives (v5.7.0)

| Primitive | Use |
|---|---|
| `AccessControlDefaultAdminRules` | Roles, plus a 2-step admin transfer with a delay. This prevents instant hand-over of admin rights. |
| `AccessControl` (roles) | `VERIFIER_ROLE` and `PAUSER_ROLE` |
| `ReentrancyGuard` | Every function that moves tokens |
| `Pausable` | Blocks creation of *new* obligations. Refunds and withdrawals are deliberately **not** pausable. |
| `SafeERC20` | All USDC transfers |
| `IERC20` / `IERC20Metadata` | Token interface; `decimals()` is checked at construction |

Custom primitives are not written where OZ has one.

## Arbitrum-specific considerations

| Topic | Finding (docs) | Clinova design consequence |
|---|---|---|
| `block.number` | Returns an *approximate L1 (Ethereum) block number*, not the Arbitrum block number | **Never use `block.number`** for deadlines. Use `block.timestamp`. |
| `block.timestamp` | Set by the sequencer clock. It may lag up to 24h or lead up to 1h. It is "reliable on the order of hours, unreliable in minutes". | Deadlines and windows are **hours-scale** (minimum windows are enforced in the spec). No logic depends on minute-level precision. |
| `blockhash` / `prevrandao` | Insecure; `prevrandao` is the constant 1 | No onchain randomness is used or needed |
| `msg.sender` via the delayed inbox | L1 contract callers are **aliased** | All actors are L2 accounts. Clinova never compares an L1 contract address. |
| Gas | 2-D fee: L2 execution plus L1 data posting, shown to users as a single fee. Use `eth_estimateGas` or `NodeInterface`. | Keep calldata small: `bytes32` hashes, no strings or arrays of metadata. Events carry hashes and IDs only. |
| Gas price | Observed Sepolia `eth_gasPrice` was ≈0.03 gwei on 2026-09-30 | Demo transactions are cheap enough for many visible state transitions |
| Ordering | First-come-first-served sequencer with no mempool. Priority fees are refunded. | Front-running by fee bidding does not apply. Designs still must not depend on ordering. |
| Finality | Soft finality comes from the sequencer feed (sub-second). Hard finality comes once the batch is on L1. | UI shows soft-confirmed status. Nothing in Clinova needs hard finality for UX. |
| Sequencer downtime | Force-inclusion via the L1 delayed inbox after ~24h | Refund and expiry windows are long enough that a sequencer outage does not force-expire honest actors unfairly |
| Block gas | ~32M effective execution cap per block | No unbounded loops. All operations are O(1) per request. |
| Precompiles | `ArbSys(100)` exposes the Arbitrum block number | Not needed |

## Other ecosystem items reviewed

- **Stylus** is a WASM VM that interoperates with the EVM and is cheaper for compute- and memory-heavy work. Clinova has **no such workload**; it is state transitions and ERC-20 accounting. Stylus would add audit risk and toolchain immaturity for no material gain. **Decision: stay on Solidity.** Future candidates would be on-chain verification of complex proofs, such as signature aggregation or ZK verification of lab-device attestations.
- **Robinhood Chain** is an Arbitrum-based L2 with ETH gas, FCFS sequencing and full EVM compatibility. Clinova has **no chain-specific assumptions**: no hardcoded addresses, token address injected, RPC by env var. Porting would mean redeploying and configuring a USDC address. No multi-chain work is planned.
- **ZeroDev / account abstraction** (ERC-4337 & EIP-7702: gas sponsorship, passkeys, session keys) is **useful later, not now.** It would let labs transact without holding ETH, let buyer back-ends and AI agents use scoped session keys, and give staff passkey logins. It needs no contract changes *provided* contracts never use `tx.origin` and never assume `msg.sender` is an EOA. That rule is part of the spec.
- **Oracles** (Chainlink, Pyth, API3, Chronicle, and others per the content map) are **not required**. Prices are denominated in USDC, so no price feeds are needed. Service verification is a human or institutional attestation, not an external data feed an oracle could supply.
- **Indexers:** the MVP reads state through RPC and events. An indexer (for example a subgraph) is a later option for marketplace discovery queries. Contracts emit complete events so one can be added without contract changes.
- **Bridging** is not needed. Arbitrum Sepolia ETH comes directly from a faucet (arbitrum.faucet.dev, QuickNode, L2Faucet, Alchemy) and USDC from Circle's faucet. The Ethereum Sepolia faucets are not needed.
