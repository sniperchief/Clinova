# Deployment scripts

`Deploy.s.sol` deploys ProviderRegistry, ClinovaEscrow, ProofOfService, ReputationRegistry and ServiceMarketplace
(in that order). The marketplace address is precomputed from the deployer nonce (n+4), and the marketplace constructor
reverts if any module's wiring is wrong. `verify()` then re-checks every reference, the token (Circle USDC on chain
421614), the admin and delay, that no operational role was pre-granted, and every parameter.

Nonce assumption: nothing else may use the deployer's nonce during the deployment (no concurrent transactions from the
same key, no `--resume` after a partial broadcast). If it does, the deployment fails closed; never use modules from a
failed deployment. Use a fresh deployer key. Env values are range-checked (out-of-range values revert).

```bash
ADMIN_ADDRESS=0x... USDC_ADDRESS=0x... forge script script/Deploy.s.sol   --rpc-url arbitrum_sepolia --account <keystore> --broadcast --verify
```

After deployment, the admin (a multisig in production) grants `VERIFIER_ROLE` and `PAUSER_ROLE` on **both**
the registry and the marketplace. Not yet broadcast to any network.
