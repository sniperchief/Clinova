import { createConfig, http } from 'wagmi'
import { injected } from 'wagmi/connectors'
import { CLINOVA_CHAIN, RPC_URL } from '../../config/contracts'

/**
 * Arbitrum Sepolia only. Browser wallets are discovered through EIP-6963 plus a generic injected fallback.
 * Reads always go through RPC_URL (never the wallet), so read-only pages work on any wallet network.
 */
export const wagmiConfig = createConfig({
  chains: [CLINOVA_CHAIN],
  connectors: [injected()],
  transports: { [CLINOVA_CHAIN.id]: http(RPC_URL) },
})

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}
