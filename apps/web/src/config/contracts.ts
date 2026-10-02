import type { Address } from 'viem'
import { arbitrumSepolia } from 'viem/chains'

/**
 * The single source of truth for where Clinova lives. Every component reads addresses from here.
 * Values are the Phase 6 deployment (docs/deployment-arbitrum-sepolia.md), verified on Arbiscan.
 */
export const CLINOVA_CHAIN = arbitrumSepolia

export const CLINOVA_ADDRESSES = {
  chainId: 421614,
  usdc: '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d',
  providerRegistry: '0x8f6817E251cb23DaF5EcC064A4380B03D20E37ed',
  serviceMarketplace: '0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0',
  clinovaEscrow: '0xcc66A42934450a67439cD7B999C3270C6BafFdef',
  proofOfService: '0xcFe3c6D4Ab8c0487e04686B182D24dD23041a436',
  reputationRegistry: '0xdab85e7Df2bEaA2E7dD455a3e86d628784B9329a',
} as const satisfies { chainId: number } & Record<string, Address | number>

/** Block of the first deployment transaction (ProviderRegistry). Event scans start here. */
export const DEPLOYMENT_BLOCK = 314_751_000n

/** Circle USDC has 6 decimals (checked onchain at deployment). All amounts are integer base units. */
export const USDC_DECIMALS = 6

export const PUBLIC_RPC_URL = 'https://sepolia-rollup.arbitrum.io/rpc'
export const RPC_URL: string = import.meta.env.VITE_ARB_SEPOLIA_RPC_URL || PUBLIC_RPC_URL

export const EXPLORER_URL = 'https://sepolia.arbiscan.io'

export const CONTRACT_LIST: { name: string; address: Address; role: string }[] = [
  { name: 'ServiceMarketplace', address: CLINOVA_ADDRESSES.serviceMarketplace, role: 'Request lifecycle' },
  { name: 'ClinovaEscrow', address: CLINOVA_ADDRESSES.clinovaEscrow, role: 'USDC custody and settlement' },
  { name: 'ProviderRegistry', address: CLINOVA_ADDRESSES.providerRegistry, role: 'Providers, stake, verification' },
  { name: 'ProofOfService', address: CLINOVA_ADDRESSES.proofOfService, role: 'Evidence commitments' },
  { name: 'ReputationRegistry', address: CLINOVA_ADDRESSES.reputationRegistry, role: 'Performance record' },
  { name: 'USDC (Circle)', address: CLINOVA_ADDRESSES.usdc, role: 'Payment token' },
]
