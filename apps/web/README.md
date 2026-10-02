# apps/web

Clinova web app: buyer, provider and verifier interfaces to the deployed contracts on Arbitrum Sepolia (Phase 7).

```bash
npm install
npm run dev        # http://localhost:5173
```

Vite + React + TypeScript, wagmi/viem. Protocol state is read from the chain only; there is no backend.
Architecture, setup, test commands and limitations: [docs/frontend.md](../../docs/frontend.md).

Contracts stay compatible with ERC-4337/EIP-7702 smart accounts (e.g. ZeroDev) for gasless and passkey UX later.
