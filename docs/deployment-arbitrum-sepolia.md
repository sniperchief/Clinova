# Clinova — Arbitrum Sepolia Deployment Record (Phase 6)

> Testnet only. Clinova records a cryptographic commitment to service evidence and uses an authorized verification process to determine whether that evidence supports completion. All request, provider and evidence data used below is **synthetic**; no patient information exists onchain.

## Summary

| Item | Value |
|---|---|
| Network | Arbitrum Sepolia |
| Chain ID | **421614** (reported by the RPC itself before broadcasting) |
| Deployment date | 2026-10-01, broadcast started 20:25:27 UTC |
| Git commit deployed | `35ba3a6` (working tree clean at deployment) |
| Compiler | solc `0.8.30`, optimizer on, 200 runs, EVM `cancun` (from `contracts/foundry.toml`) |
| RPC | `https://sepolia-rollup.arbitrum.io/rpc` (public) |
| Explorer | https://sepolia.arbiscan.io |
| Deployer | `0x71946c64795657097905949b6Edc25009D4D94f2` (dedicated testnet key; nonces 0–4) |
| Admin (`DEFAULT_ADMIN_ROLE`, both contracts) | `0xB4B8B6CD7C7adB5c68472A8092d2f7f747BF83C5` — **EOA, temporary testnet admin** (see "Admin" below) |
| Verifier (`VERIFIER_ROLE`, registry + marketplace) | `0xe95BA811aE6c6e16A9F1b16075966155B5Ea088D` |
| Pauser (`PAUSER_ROLE`, registry + marketplace) | `0xB4B8B6CD7C7adB5c68472A8092d2f7f747BF83C5` (the admin; no separate pauser account yet) |
| USDC | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` — Circle USDC (developers.circle.com/stablecoins/usdc-contract-addresses); checked onchain: code present, "USD Coin"/USDC, 6 decimals, not paused |

## Contracts

| Contract | Address | Deploy tx | Block | Nonce | Explorer (verified source) |
|---|---|---|---|---|---|
| ProviderRegistry | `0x8f6817E251cb23DaF5EcC064A4380B03D20E37ed` | `0xe1d0f51e17ecffecc0279f418f1986fea6d9dd9c13990b6bb68b084f873e2c1e` | 314751000 | 0 | https://sepolia.arbiscan.io/address/0x8f6817E251cb23DaF5EcC064A4380B03D20E37ed#code |
| ClinovaEscrow | `0xcc66A42934450a67439cD7B999C3270C6BafFdef` | `0x71cdad51929d93a59ba9324e815182524d865403c5d95bae04c739aee17ff9a9` | 314751008 | 1 | https://sepolia.arbiscan.io/address/0xcc66A42934450a67439cD7B999C3270C6BafFdef#code |
| ProofOfService | `0xcFe3c6D4Ab8c0487e04686B182D24dD23041a436` | `0x90c2d7353fa3da120e36f82c14949b3cc0976f07dc4a8b1a7376d1704d2646da` | 314751022 | 2 | https://sepolia.arbiscan.io/address/0xcFe3c6D4Ab8c0487e04686B182D24dD23041a436#code |
| ReputationRegistry | `0xdab85e7Df2bEaA2E7dD455a3e86d628784B9329a` | `0x1119bf7a8f5472be3e39c91068087b0668b9f4dca41824edc000e2556656a861` | 314751040 | 3 | https://sepolia.arbiscan.io/address/0xdab85e7Df2bEaA2E7dD455a3e86d628784B9329a#code |
| ServiceMarketplace | `0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0` | `0xeffecfcc3f0d3104c3ad2675fbf58539e567e5c910710573aa974e9be4c9e7db` | 314751058 | 4 | https://sepolia.arbiscan.io/address/0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0#code |

All five addresses equal `CREATE(deployer, nonce)` computed before broadcasting, and the marketplace equals the script's prediction (nonce n+4). Every transaction has status 1. Total deployment gas: 8,970,588.

**Explorer verification:** Forge reported `Pass - Verified` for all five ("All (5) contracts were verified!"), and Etherscan's API (`getsourcecode`, chain 421614) independently returns, for each contract: the correct contract name, compiler `v0.8.30+commit.73712a01`, optimization 1, runs 200, EVM `cancun`, and constructor arguments. Sourcify submissions were also made by Forge.

## Parameters (deploy-script defaults, unchanged)

| Parameter | Value |
|---|---|
| `minStake` | 100 USDC at deployment; **lowered to 20 USDC** on 2026-10-01 (see "Parameter changes") |
| `unbondingPeriod` | 7 days |
| `minPrice` | 1 USDC |
| `reviewPeriod` | 7 days |
| `disputePeriod` | 14 days |
| Admin transfer delay | 2 days |

## Commands

```bash
# preflight (all passed): forge fmt --check, forge clean, forge build, forge test (414 passed, 0 failed),
# forge coverage (100%), forge lint (4 triaged warnings), dry run against the live RPC
cd contracts
set -a; source ../.env; set +a        # ARB_SEPOLIA_RPC_URL, USDC_ADDRESS, ADMIN_ADDRESS, ARBISCAN_API_KEY
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia \
  --account clinova-deployer --password-file <outside-repo>/deployer.pw \
  --sender 0x71946c64795657097905949b6Edc25009D4D94f2 --broadcast --slow --verify
```

Explorer verification ran as part of `--verify` (Etherscan V2 API key; Foundry also submitted to Sourcify). To re-verify one contract manually:

```bash
forge verify-contract <address> src/ServiceMarketplace.sol:ServiceMarketplace --chain 421614 --watch \
  --constructor-args $(cast abi-encode "constructor(address,uint48,address,address,address,address,uint256,uint32,uint32)" ...)
```

Signing used Foundry encrypted keystores; `PRIVATE_KEY` in `.env` was empty. No key, password or API key appears in this repository.

## Post-deployment verification (onchain, independent of the script)

The script's own `verify()` ran inside the broadcast and passed. Every value was then re-read from the live contracts:

| Check | Result |
|---|---|
| Bytecode present | all five (11,801 / 3,720 / 4,151 / 2,953 / 14,665 bytes) |
| Marketplace → registry, escrow, PoS, reputation, usdc | all correct |
| Registry, escrow, PoS, reputation → marketplace | all `0x38d4…6Ef0` |
| Reputation → registry, PoS | correct |
| Token everywhere | Circle USDC |
| Admin / delay (both) | `0xB4B8…83C5` / 172,800 s |
| Deployer roles | **none** on either contract |
| Roles at deployment | admin held only `DEFAULT_ADMIN_ROLE`; no verifier or pauser existed until granted |
| Initial state | not paused, `nextRequestId = 1`, nothing staked or locked |

### Role grants (by the admin, after deployment)

| Grant | Tx | Block |
|---|---|---|
| `VERIFIER_ROLE` → verifier on registry | `0x06d02dd3b743e740a475d0b3da812338315f1a8ddea5613e97d28e049c601e82` | 314753581 |
| `VERIFIER_ROLE` → verifier on marketplace | `0x6a40be14827fc706ebd0a7d4593823b6280e5cc1f2aad06b6ffb02cd3134f1ae` | 314753647 |
| `PAUSER_ROLE` → admin on registry | `0xb8df71e175f92be5f8f8c98e651e75f81c2881c1ec826f47ebfe939c082b9054` | 314753733 |
| `PAUSER_ROLE` → admin on marketplace | `0x76a290489d86215a71398db69b55b0eb76a10d89aa7ee08b891c7f64ef7ee62e` | 314753789 |

## Test accounts (public addresses only)

| Role | Address |
|---|---|
| Admin / pauser | `0xB4B8B6CD7C7adB5c68472A8092d2f7f747BF83C5` |
| Verifier | `0xe95BA811aE6c6e16A9F1b16075966155B5Ea088D` |
| Provider (provider ID = address) | `0xd0091F4cc400E63C2401A026AFb2bC5DDEf0F94D` |
| Buyer | `0xfD858980c4Dc0F55919BACe10C25743a8218ED5B` |

All distinct. USDC came from Circle's faucet (faucet.circle.com); ETH from a faucet, bridged and distributed by ordinary transfers. No balance was fabricated and no storage was modified.

Synthetic identifiers: service type `keccak256("LAB.CBC.V1")`; region `0x5eb3a49f…bc9c` = salted hash of the coarse code `NG-RI:PortHarcourt`; provider metadata `0xfb91ce58…952c` = hash of a synthetic profile label; evidence commitments follow spec §5 (`keccak256(abi.encode("CLINOVA_EVIDENCE_V1", bundleHash, salt))`) over synthetic bundles with random salts.

## End-to-end flow with real USDC (request #1, 25 USDC)

State was re-read after every step; the "Check" column is what was observed.

| # | Step | Caller | Tx | Block | Check |
|---|---|---|---|---|---|
| 1a | Approve registry 100 USDC | provider | `0x9f39a7d719589277eba82ff8bf0dd884e37b7ee3a30008ae952a6f46f0d9030b` | 314754122 | allowance 100 USDC |
| 1b | Register + stake 100 USDC, capability CBC | provider | `0xf11cf5212a33de8a1da978fc3a7e9e0243b4cf8d98eea2b03c1472761d5f7034` | 314754328 | registered, stake 100, offers CBC; registry holds 100 USDC = `totalStaked` |
| 2 | Verify provider | verifier | `0x4b96032d895cb4266f66373fb6780826a0b2fc6be63b6c9bfc758e92d0323a16` | 314754455 | verified |
| 3 | Activate | provider | `0x69856c5c2e1092a3db25e015a8ee2a7ae3994b76de5b865377583dee02c61a79` | 314754484 | active, `isEligible(CBC)` true |
| 4a | Approve marketplace 25 USDC | buyer | `0x9872a15550bdfbc701b4d55319301c0a64d74689d16fc09eba27d46b08dda6da` | 314754639 | — |
| 4b/5 | Create request #1 and fund escrow (atomic) | buyer | `0xe62e3fc44a539c5342e63e82b3233c86f0905f8a3992482a2dd7dfef994ab474` | 314754656 | OPEN, buyer/price/deadlines correct; deposit FUNDED 25; escrow holds 25 USDC |
| 6 | Accept | provider | `0x1e61fc63583104fac27c81a94e4eed313432a628784da6325a50537ca83f718e` | 314754753 | ACCEPTED; request provider = registry job provider = escrow payee = provider; activeJobs 1 |
| 7 | Start service | provider | `0xe4da84fe3a04abf4e98ef4cffa0ebf9afba2e27ff3110b67d4f3efeea384dfa9` | 314754837 | IN_SERVICE |
| 8 | Submit proof (salted commitment) | provider | `0x2db930c66089ddb7f93d1ec28e08a1c778a00eaa21cf3f3b66de84eaa4836361` | 314754873 | COMPLETED; proof SUBMITTED, bound to provider; stored proofHash = `computeProofHash(1, provider, commitment)` |
| 9–10, 12 | Verifier approves → settlement, job close, reputation | verifier | `0x847ed94a655c3f3b1a6d2cda7155f8dc76957464201701e860cf0d0cb17a7c85` | 314755299 | SETTLED; proof APPROVED (reviewer = verifier); deposit RELEASED to provider; job CLOSED; credit 25; reputation (completed 1, successful 1, failed 0, disputes 0), recorded once |
| 11 | Provider withdraws | provider | `0x8ddd09ddfbc13838b11e2e68847ca11f920a52503bb6aece71286d754b0723ce` | 314755484 | provider USDC 20 → 45 (exactly +25); credit 0; escrow 0 |
| 13a | Request unstake (stake exit) | provider | `0x91dd5a43736b46bd88c9e877c963f61c0314d4b53ffadd03301660f46a9d5a1f` | 314757220 | unbonding until 2026-10-08 20:52:08 UTC; inactive; early withdraw reverts `UnstakeNotReady` |

After settlement: a second approval and a late buyer confirmation revert (`InvalidStatus(1, 5)`); a second withdrawal reverts (`NothingToWithdraw`).

## Dispute path, provider fault (request #2, 25 USDC)

| Step | Caller | Tx | Block |
|---|---|---|---|
| Approve 25 USDC | buyer | `0x8e6269b0da4b9772a3d95018ee3d960fdde71a239e96d9de5b036c3727664eb5` | 314755691 |
| Create + fund #2 | buyer | `0x541028952fec51360c15a9407f4368551e8a9383d87f8bae27a8a91d277b9b96` | 314755710 |
| Accept | provider | `0xc40a971e280c5a6464c6a4e883248fc0d0cbb96058768440c6076ef01853dd33` | 314755754 |
| Start | provider | `0xd5445eb2ed27f3bcf7dae0241e82ef07b9f64bbdd10b02c3fe48f7c19fc1045d` | 314755771 |
| Submit proof | provider | `0x672f70507dec4291078520cf154072031326fc1f97a01eb443849186f8121d79` | 314755794 |
| Open dispute (synthetic reason hash) | buyer | `0x7511909d70a3ec79f1152f0d63c3e688194ea9ff1b2aa3d2d1d4ca677c8b18bf` | 314755838 |
| Resolve `REFUND_PROVIDER_FAULT` | verifier | `0xd96784a100fd928d9672dce753b62f763a872f35d2387d7aa613949ff9dacca6` | 314755970 |
| Buyer withdraws refund | buyer | `0x64377ea27895a98440a2304ed135779678f7420836c8627c2fd639c982451e03` | 314756122 |

Result: DISPUTED (from COMPLETED) → REFUNDED; proof REJECTED (final); escrow REFUNDED once; buyer +25 USDC exactly (50 → 75); provider credit 0; job closed; reputation (completed 2, successful 1, **failed 1**, **disputes 1**). Before resolution, the buyer, the provider and the admin (no verifier role) could not resolve, and an early timeout reverted `DeadlineNotPassed`. A second resolution reverted `InvalidStatus(2, 9)`.

## Refund path: provider accepts and fails to deliver (request #3, 25 USDC) — **pending**

| Step | Caller | Tx | Block |
|---|---|---|---|
| Approve 25 USDC | buyer | `0x3130eb908ad6936d54545521c7a88c538caaad03aba2e6ebc6fe39ec0212eb0a` | 314756226 |
| Create + fund #3 (shortest legal windows: accept +1h, service +6h) | buyer | `0x693251c2249722f2d22f735092b38c822c1b4c26a09d5a7882ddf18ff3cb3649` | 314756245 |
| Accept, then deliberately no service | provider | `0xbb0b62798568c76b5d1029b0441a308a18cddaf6f241a2f912e7d5c5dc47a0e7` | 314756262 |

Verified now: ACCEPTED, escrow FUNDED 25, job OPEN, provider stake held. Early expiry (`DeadlineNotPassed`) and cancellation (`InvalidStatus(3, 2)`) revert. **To complete after `serviceDeadline` = 2026-10-02 03:49:57 UTC:** buyer calls `expireRequest(3)` (refund 25 USDC, job closed, `failedJobs` +1), then `withdraw()`. No parameter was shortened and no time was faked.

## Cancel refund while paused, and pause/unpause (request #4, 5 USDC)

| Step | Caller | Tx | Block | Check |
|---|---|---|---|---|
| Approve | buyer | `0x33b9caa122174cd631279a00dcf763a18f09f838661589bd8333614d0080dd5a` | 314756450 | — |
| Create + fund #4 | buyer | `0x5c9cf6429a8bf4c69ee422f455d052b97dee0c30fa149081324f6918db9cf7c4` | 314756466 | OPEN |
| **Pause marketplace** | admin (pauser) | `0x4b7e3bb06c008f3656201bd9dc2f8aaec49627a94b959268638897b6cdd99d6e` | 314756485 | `createRequest` and `acceptRequest` revert `EnforcedPause` |
| Cancel #4 while paused | buyer | `0x12960643ea3c4976c4ff6a3f4e2d87d2bfbc5b5d15444ed3d20a00879528281f` | 314756538 | CANCELLED, escrow REFUNDED, credit 5 |
| Withdraw while paused | buyer | `0x40cba10a30352b71bf9d222fd72b9fc9ac331972a9181d87a7e1bb07d54a2230` | 314756613 | buyer +5 USDC exactly |
| **Unpause** | admin (pauser) | `0x8a58485042cd26b8b889ee0de3ecaf8d39a7cf34259122f2d94ac0d13636dea2` | 314756650 | not paused; `createRequest` simulation succeeds |

The deployed system was left **unpaused**.

## Verifier conflict of interest (request #5, 1 USDC)

The verifier acted as a buyer (1 USDC transferred from the buyer: `0xa07a3c0578b8d82548e10b6f5b682b8ef3591321db0c838e6ef73c542d38d554`). Approve `0x2de9705d…69f6`, create #5 `0x10cda147…2a71`, accept `0x523f9252…9ab9`, start `0x4a6adfd5…ea34`, proof `0xc3d4c61e…33a8`. The verifier's `approveProof(5)` and `rejectProof(5)` both revert `ConflictOfInterest(verifier)` despite it holding `VERIFIER_ROLE`. It could only confirm as the buyer (`0xcfa7a47dc8df6417f62011d1ad426488bdce249d329fca003da6329ebdfb6919`): SETTLED, proof BUYER_ACCEPTED. The provider withdrew exactly 1 USDC (`0xf93f7e6e237382c9587e5644a436b9fcbb625d327a800ab4e27c71af6269a156`).

## Access control on the live contracts

Simulated with `eth_call` from each account against the deployed contracts (no gas spent); each reverted with the expected reason:

| Attempt | Revert |
|---|---|
| Buyer / provider / admin calls `approveProof` | `AccessControlUnauthorizedAccount(…, VERIFIER_ROLE)` |
| Provider calls `setMinPrice`; provider grants itself `VERIFIER_ROLE` | `AccessControlUnauthorizedAccount(…, DEFAULT_ADMIN_ROLE)` |
| Buyer calls `pause` | `AccessControlUnauthorizedAccount(…, PAUSER_ROLE)` |
| Random account `escrow.release`; admin `escrow.refund` | `OnlyMarketplace` |
| Random account `escrow.withdraw` | `NothingToWithdraw` |
| Random account `reputation.recordOutcome`; admin `proofOfService.approve`; random `registry.recordJobClosed` | `OnlyMarketplace` |
| Admin `withdrawStake` | `NoUnstakeRequested` |
| Buyer cancels after acceptance; verifier submits the provider's proof | `InvalidStatus(1, 4)` |
| Provider confirms its own completion | `NotBuyer(1)` |
| Anyone closes unreviewed before the deadline | `DeadlineNotPassed` |
| Buyer / provider / admin resolve a dispute | `AccessControlUnauthorizedAccount(…, VERIFIER_ROLE)` |
| Verifier approves or rejects its own request | `ConflictOfInterest` |

## Not demonstrated live (time-bound), and why

| Behaviour | Live status | Evidence |
|---|---|---|
| Unreviewed completion refunds the buyer (never pays the provider) | Needs the 7-day `reviewPeriod`; parameters were not shortened | Configuration verified onchain (`reviewPeriod = 604800`); behaviour proven in Phase 5 (`LivenessTest.test_BuyerDisappears_NoVerifier_RefundNotPayment`, state matrix, invariants, fork `test_Fork_RefundAndDisputePaths`) |
| Dispute timeout | Needs the 14-day `disputePeriod` | `disputePeriod = 1209600` onchain; early timeout attempt reverted `DeadlineNotPassed`; proven in Phase 5 fork/invariant suites |
| Stake withdrawal | Unbonding ends 2026-10-08 20:52:08 UTC and requires request #3 closed | Pending; early attempt reverts `UnstakeNotReady` |

## State at the end of Phase 6 testing

| Item | Value |
|---|---|
| Requests | #1 SETTLED, #2 REFUNDED, #3 ACCEPTED (pending expiry), #4 CANCELLED, #5 SETTLED; `nextRequestId = 6` |
| Escrow | 25 USDC held = `totalLocked` (request #3); `totalCredited` 0; surplus 0 |
| Registry | 100 USDC held = `totalStaked` (provider, unbonding) |
| Provider reputation | completed 3, successful 2, failed 1, disputes 1 (one record each for #1, #2, #5) |
| Paused | marketplace no, registry no |

## Admin and trust assumptions

- The admin is a **single EOA, used as a temporary testnet admin** with the project owner's explicit consent; no multisig was available. Before any non-test use, hand admin to a Safe through the built-in 2-step transfer (`beginDefaultAdminTransfer` → wait 2 days → `acceptDefaultAdminTransfer`), ideally behind a timelock.
- Residual risk R5-1 (security-review.md) applies: whoever controls the admin key can grant itself `VERIFIER_ROLE` and get a sybil provider paid for undirected OPEN requests. This was **not** exercised on the testnet. Verified instead: the admin has no escrow or stake path (`OnlyMarketplace`, `NoUnstakeRequested`), cannot approve proofs without the verifier role, and every role grant above is a public `RoleGranted` event.
- The pauser is currently the admin key. A dedicated pauser can be granted later.

## Parameter changes after deployment

| Date | Change | Caller | Tx | Block |
|---|---|---|---|---|
| 2026-10-01 22:41:11 UTC | `ProviderRegistry.setMinStake`: 100 USDC → **20 USDC** (`ParameterUpdated("MIN_STAKE", 100000000, 20000000)`) | admin `0xB4B8…83C5` | `0x774befe98394ac514cacae411d1b815c326a5a277444ee9f9e0f37e504ca2d69` | 314783390 |

Reason: lower the testnet entry cost so providers can be onboarded with the test USDC available from the faucet. This uses the existing bounded admin setter (0 < minStake ≤ 100,000 USDC); no contract code changed. Existing stakes and pending unbonding are unaffected; the new minimum applies to registration, activation and eligibility from now on. To restore: `setMinStake(100000000)`.

## Follow-up actions

1. After 2026-10-02 03:49:57 UTC: buyer `expireRequest(3)` → `withdraw()`; check `failedJobs` becomes 2 and the job is closed.
2. After 2026-10-08 20:52:08 UTC: provider `withdrawStake()`; check +100 USDC and registry `totalStaked = 0`.
3. Move admin to a multisig before using this deployment beyond testing.
