import { connectorsForWallets, type WalletList } from '@rainbow-me/rainbowkit'
import {
  braveWallet,
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  rainbowWallet,
  trustWallet,
  walletConnectWallet,
} from '@rainbow-me/rainbowkit/wallets'
import { createConfig, http } from 'wagmi'
import { CLINOVA_CHAIN, RPC_URL } from '../../config/contracts'

/**
 * Wallet connection via RainbowKit, Arbitrum Sepolia only.
 * Reads always go through RPC_URL (never the wallet), so read-only pages work on any wallet network.
 *
 * VITE_WALLETCONNECT_PROJECT_ID is optional. Without it only browser-extension wallets are offered (RainbowKit
 * refuses WalletConnect-based wallets without a project ID); with it, mobile and QR-code wallets are added.
 */
export const WALLETCONNECT_PROJECT_ID: string = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || ''

const APP = {
  appName: 'Clinova',
  appDescription: 'The real-world healthcare infrastructure layer for telemedicine.',
  appUrl: typeof window !== 'undefined' ? window.location.origin : 'https://clinova.app',
  appIcon: typeof window !== 'undefined' ? `${window.location.origin}/brand/icon-192.png` : undefined,
}

const wallets: WalletList = WALLETCONNECT_PROJECT_ID
  ? [
      { groupName: 'Recommended', wallets: [metaMaskWallet, rabbyWallet, coinbaseWallet, rainbowWallet] },
      { groupName: 'More', wallets: [trustWallet, braveWallet, walletConnectWallet, injectedWallet] },
    ]
  : [{ groupName: 'Browser wallets', wallets: [injectedWallet, rabbyWallet, braveWallet, coinbaseWallet] }]

const connectors = connectorsForWallets(wallets, { ...APP, projectId: WALLETCONNECT_PROJECT_ID || 'unset' })

export const wagmiConfig = createConfig({
  chains: [CLINOVA_CHAIN],
  connectors,
  transports: { [CLINOVA_CHAIN.id]: http(RPC_URL) },
})

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}
