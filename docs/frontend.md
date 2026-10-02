# Clinova Web App (Phase 7)

The web app in `apps/web` is the product interface to the deployed Clinova contracts on **Arbitrum Sepolia**. All protocol state (requests, escrow, stake, proofs, reputation, roles, pause status) is read from the chain. There is no backend and no database.

> Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion. The app does not claim that the blockchain proves a medical service happened, and it never puts patient information onchain.

## Stack

| Concern | Choice |
|---|---|
| Build / dev server | Vite 8, TypeScript 5.9 (strict), React 19 |
| Wallet and chain | wagmi 3 + viem 2. Injected wallets via EIP-6963 discovery plus a generic injected fallback. No WalletConnect project ID needed. |
| Server state | TanStack Query (polls every 15 s; all queries are invalidated after every confirmed transaction) |
| Routing | react-router 7 |
| Styling | Plain CSS with design tokens (`src/index.css`), Inter Variable (self-hosted via `@fontsource-variable`) |
| Tests | Vitest (unit, live read-only, fork lifecycle), playwright-core driving system Microsoft Edge (UI end-to-end) |

There was no existing frontend in the repository, so this is a new package. It does not change the contracts or the Foundry setup.

## Architecture

```text
apps/web/src
├── config/
│   ├── contracts.ts        ← the only place addresses, chain ID, deployment block, RPC and explorer are defined
│   └── catalog.ts          ← public service-type and region catalogs; SYNTHETIC demo labels
├── lib/
│   ├── contracts/
│   │   ├── abis.ts         ← GENERATED from contracts/out by scripts/sync-abis.mjs (do not edit)
│   │   ├── types.ts        ← mirrors ClinovaTypes.sol enums/structs, plus plain-language labels
│   │   ├── reads.ts        ← every contract read and event scan (multicall; plain functions over a viem client)
│   │   ├── calls.ts        ← every write the app can make, as call descriptors
│   │   └── requestActions.ts ← which actions a wallet may take in each request state (mirrors spec §1)
│   ├── commitments.ts      ← salted evidence commitments, dispute-reason hashes, profile hashes
│   ├── errors.ts           ← custom errors / wallet errors → plain language, with technical details kept
│   ├── format.ts           ← bigint USDC parsing/formatting, dates, explorer URLs
│   ├── localRecords.ts     ← browser-local, presentation-only offchain documents (see "Data boundaries")
│   ├── providerLabel.ts, activity.ts
│   └── web3/wagmi.ts       ← wagmi config (Arbitrum Sepolia only)
├── hooks/
│   ├── useClinova.ts       ← react-query hooks over lib/contracts/reads.ts; role/eligibility/clock helpers
│   └── useTx.ts            ← the single write path: chain guard → simulate → wallet → receipt → refresh
├── components/             ← Layout, Wallet (connect, network gate), Tx (status, buttons, steps), Request, Provider, ui
└── pages/                  ← Landing, Discover, Buyer, NewRequest, RequestDetail, Provider, Verifier
```

**One write path.** Every transaction goes through `useTx.run(call)`:

1. Refuses to proceed unless a wallet is connected **and** on chain 421614 (writes also pass `chainId`, a second guard).
2. `simulateContract` against the live contract with the call's ABI plus every Clinova custom error, so a revert from a nested module (e.g. `ProviderNotEligible` from the registry during `acceptRequest`) is decoded before the wallet opens. Nothing is signed for a call the contract would reject.
3. Wallet signature → **Confirming** (hash known, Arbiscan link shown) → receipt. **Confirmed** is shown only for a receipt with `status: success`; a reverted receipt is shown as failed.
4. All protocol queries are invalidated, so the UI re-reads chain state.

States shown to the user: *Checking with the contract*, *Waiting for wallet confirmation*, *Submitted — confirming on Arbitrum*, *Confirmed onchain* (+ Arbiscan link), *Failed* (plain-language reason + expandable technical details).

**Actions are state-gated.** `requestActions.ts` encodes the transition table (docs/contract-spec.md §1): a settled request shows "Settlement complete", never "Confirm completion"; a verifier who is a party to a request is not offered review actions; `PROVIDER_WINS` is disabled unless the proof is still under review; cancellation, expiry, withdrawals and refunds remain available while the marketplace is paused. These checks are **UX only** — the contracts remain the security boundary, and every action is also simulated.

**Token amounts** are `bigint` base units end to end (`parseUsdc` / `formatUsdc`, 6 decimals). No floating point is used for USDC. Approvals are for the exact amount, never unlimited.

**Provider discovery.** Providers are not enumerable onchain, so the app rebuilds the set from `ProviderRegistered` / `ProviderCapabilityAdded` events since the deployment block, then reads each provider's current record, services (`offersService`) and reputation by multicall. Eligibility is computed with the registry's own rule and the live `minStake`.

**Timelines and transaction links** come from contract events, so every step on a request page links to its real transaction on `https://sepolia.arbiscan.io`.

## Data boundaries

| Data | Where it lives | Notes |
|---|---|---|
| Request status, deadlines, price, escrow state, stake, verification, proofs, reputation, roles, pause | **Chain** | The only source of truth; never cached outside react-query |
| Service types | Chain stores `keccak256("LAB.CBC.V1")`; names come from `config/catalog.ts` | Unknown codes are shown as their hash |
| Service area | Chain stores `keccak256("CLINOVA_REGION_V1:<code>")` (coarse, public region codes per docs/architecture.md) | Regions not in the catalog (e.g. the Phase 6 provider's salted region) show as "Unlisted region" |
| Provider display name | Chain stores `metadataHash = keccak256(canonical JSON profile)`. The profile JSON is saved in the registering browser's `localStorage` and only displayed if it hashes to the onchain value. | Other browsers see "Unlabelled provider" — see limitations |
| Evidence | **Never leaves the provider's device.** The file is hashed in the browser; the bundle (manifest naming chain, ProofOfService, request, provider + file hash) is salted per spec §5. Only the 32-byte commitment is submitted. | The evidence package (bundle + salt) can be downloaded; it is also kept in `localStorage` for same-browser demos |
| Dispute / rejection reasons | Salted hash onchain; the reason record stays in the browser | Users are told not to include patient data |
| Demo labels | `DEMO_DIRECTORY` in `config/catalog.ts` | Shown with a "demo" tag; synthetic |

The verifier page includes an **evidence package check**: it recomputes the commitment from a package and verifies the manifest names this chain, ProofOfService address, request and provider (residual risk R5-3). It proves the package is the one committed onchain; judging the evidence remains the verifier's job.

## Local setup

Requirements: Node.js ≥ 20 (tested with 24), npm, and a browser wallet (MetaMask, Rabby, …).

```bash
cd apps/web
npm install
npm run dev            # http://localhost:5173
```

Production build: `npm run build` (output in `apps/web/dist`, a static site), preview with `npm run preview`. When hosting, rewrite unknown paths to `index.html` (client-side routing).

### Environment variables

| Variable | Required | Meaning |
|---|---|---|
| `VITE_ARB_SEPOLIA_RPC_URL` | No | RPC for reads. Default: public `https://sepolia-rollup.arbitrum.io/rpc`. Anything prefixed `VITE_` is **bundled into the browser and public** — never use a key with billing or write access. |

Copy `apps/web/.env.example` to `apps/web/.env.local` if needed. No secret is required to run the app.

### Wallet setup

1. Add Arbitrum Sepolia to the wallet (the app offers **Switch network**, which adds/switches via the wallet; chain ID `421614`).
2. Get Sepolia ETH for gas from an Arbitrum Sepolia faucet.
3. Get test USDC from https://faucet.circle.com (select Arbitrum Sepolia). Token: `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`.
4. Use separate accounts for buyer, provider and verifier — the contracts forbid a buyer accepting its own request and a verifier reviewing its own.

### Deployed contracts (from `src/config/contracts.ts`)

| Contract | Address |
|---|---|
| ProviderRegistry | `0x8f6817E251cb23DaF5EcC064A4380B03D20E37ed` |
| ServiceMarketplace | `0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0` |
| ClinovaEscrow | `0xcc66A42934450a67439cD7B999C3270C6BafFdef` |
| ProofOfService | `0xcFe3c6D4Ab8c0487e04686B182D24dD23041a436` |
| ReputationRegistry | `0xdab85e7Df2bEaA2E7dD455a3e86d628784B9329a` |
| USDC (Circle) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |

Explorer: https://sepolia.arbiscan.io. ABIs: `npm run abis` regenerates `src/lib/contracts/abis.ts` from `contracts/out` (run `forge build` first).

## Testing the flows manually (real Arbitrum Sepolia)

**Provider** (account P, holding at least the current minimum stake, shown in the app):
1. *Providers* → enter a synthetic business name, area and services; stake is pre-filled with the live `minStake`.
2. *Step 1 of 2 Approve USDC* → *Step 2 of 2 Register as provider*. Dashboard shows *Awaiting verification*.
3. A verifier verifies (below). Back on *Providers*, click **Activate**. Status: *Verified · accepting requests*.

**Verifier** (an account holding `VERIFIER_ROLE`; on the testnet deployment that is `0xe95B…088D`):
1. The *Verifier* nav item appears only for wallets with the role.
2. *Providers awaiting verification* → **Verify** (after offchain checks).
3. *Pending proof reviews* → load the provider's evidence package (or it is found automatically in the same browser) → **Approve**, or **Reject…** with a reason.
4. *Active disputes* → **Resolve dispute** → choose an outcome.

**Buyer** (account B, ≠ P, with USDC):
1. *Discover* → filter by service/area → **Request a service** (or *Healthcare businesses → New request*).
2. Review → *Approve USDC* → *Create request* (creation and escrow funding are one transaction). You land on the request page.
3. As P: open the request → **Accept job** → **Start service** → **Use synthetic demo evidence** (or choose a file; it is hashed locally) → **Submit proof**.
4. As B: **Confirm completion**, or **Submit dispute**; or let the verifier approve.
5. As P: *Providers* → **Withdraw earnings**. Reputation counters update on the provider card and dashboard.

Every step links to its Arbiscan transaction.

## Automated tests

| Command | What it does | Network |
|---|---|---|
| `npm run typecheck` / `npm run lint` / `npm run build` | Static checks and production bundle | none |
| `npm test` | Unit tests: bigint USDC math, commitment encoding (checked against a Foundry `cast` reference), evidence-package checks, the full action/state table | none |
| `npm run test:live` | Read-only integration against the **deployed** contracts: wiring, parameters, provider discovery, reputation, Phase 6 request states and tx hashes, onchain proof-hash binding, role detection, and simulated writes (`eth_call`, no gas) decoded into plain-language errors | Arbitrum Sepolia (reads only) |
| `npm run test:fork` | Full write lifecycle on a **local anvil fork** of Arbitrum Sepolia through the app's call builders: close Phase 6 leftovers, onboard a new provider, create+fund, accept/start/proof, verifier approval, settlement, withdrawal, reputation; dispute refund; pause (acceptance blocked, cancel/withdraw allowed) | local fork (needs Foundry's `anvil`) |
| `node e2e/ui-flow.mjs [dir]` | Drives the **real UI** in headless Microsoft Edge against a local fork with a test-only EIP-1193 wallet shim (impersonated public test accounts; no keys). Covers connect, wrong-network handling, onboarding, verification, activation, discovery, request creation with approval, accept/start/proof, evidence check and approval, withdrawal, settlement view with Arbiscan links, and responsive layouts at 390 px and 820 px. Saves screenshots. | local fork |

Fork-based tests never broadcast to the real network. The wallet shim exists only in `e2e/` and is not part of the app bundle.

## Real testnet run through the web app (2026-10-02)

The full flow was performed by hand in the web app with browser wallets on Arbitrum Sepolia, after the minimum stake was lowered to 20 USDC (see docs/deployment-arbitrum-sepolia.md, "Parameter changes"). State was re-read from the contracts afterwards.

| Step | Actor | Tx | Block |
|---|---|---|---|
| Register + stake 20 USDC, capability listed | provider `0x9C7b…9584` | `0x2b6c00e460f88c54311eaad25ffc67f309ff359ec246a8b9597a52cd435afecc` | 314784850 |
| Verify provider | verifier `0xe95B…088D` | `0xb86ac6bd7b49bf84633815f544bdfbaa34fd85a23a7016f84399320aa5c68907` | 314786070 |
| Activate | provider | `0x3618ec7b9a552870ee7b80d1450c853aea38dda424f4078455064926a8d65af0` | 314786240 |
| Create + fund request #6 (5 USDC, atomic) | buyer `0x3fc9…55B3` | `0x7011dfbf84e2c831bfb8fad2400a5bf42d1150f360db72eb5b799ea306a8e343` | 314795269 |
| Accept | provider | `0x5c86a55dd39f30a56bc41bde35ce7c7f90811f12bbecf8ce5c86ccdfdbfdbcad` | 314795555 |
| Start service | provider | `0xa7895cd1b28ec454d053b143d47a6c5f5d773d51bd4e33d40fa9d3587f13ca9b` | 314795739 |
| Submit proof (salted commitment) | provider | `0xaba50b18629599dff200b1dc685669dc11e6bdbce8bdda50e687fa0114f52760` | 314796204 |
| Verifier approves → settled, reputation recorded | verifier | `0xc1716b063705fbe73eefcf885310ad64a6d5bf34dce79de7042135c285875a02` | 314796700 |
| Withdraw earnings | provider | `0x530b2064c1fca51207c1d5143a416e673b1c91fdc6c84762ddd447076e212c8a` | 314796982 |

Final state: request #6 `SETTLED`; provider registered, verified, active, stake 20 USDC, no open jobs, escrow credit 0 (withdrawn); reputation completed 1, successful 1, failed 0, disputes 0.

## Known limitations

- **Real-network writes need a human wallet.** Automated write tests run on a local fork; on the real testnet the flow is exercised manually (done once end to end on 2026-10-02, above). The dispute and pause paths were exercised on the fork and in Phase 6, not through the web app on the real testnet.
- **Provider names are browser-local.** The contracts store only a profile hash and there is no metadata service yet, so a provider's name is visible only in the browser that registered it (verified against the onchain hash) or for the synthetic demo labels. Elsewhere it shows "Unlabelled provider" with its address and onchain data.
- **Evidence packages are handed over manually** (download/upload JSON, or same-browser storage). The encrypted evidence channel to the verifier (`services/verification`) is not built.
- **Event scanning from the client.** Discovery and timelines scan logs from the deployment block. This is fast on the public RPC today; at much larger scale an indexer would be needed. The app falls back to chunked ranges if an RPC caps `eth_getLogs`.
- **Region matching is informational.** The contracts do not enforce location; the area filter only matches catalog region hashes.
- **Verification is trusted.** Verifiers are an authorized role; the app does not and cannot verify medical work itself.
- **Deadlines use the browser clock** for display and pre-checks; the contract uses `block.timestamp` and remains authoritative (pre-flight simulation catches any skew).
- **Testnet only; contracts not externally audited.**
