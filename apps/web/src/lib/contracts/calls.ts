import { erc20Abi, type Abi, type Address, type Hex } from 'viem'
import { CLINOVA_ADDRESSES as A } from '../../config/contracts'
import { clinovaEscrowAbi, providerRegistryAbi, serviceMarketplaceAbi } from './abis'
import type { Resolution } from './types'

/**
 * Every write the app can make, as plain call descriptors. The UI never builds calldata elsewhere; the
 * transaction hook (hooks/useTx.ts) simulates, sends and confirms these, and the fork test executes the same ones.
 */
export interface ContractCall {
  address: Address
  abi: Abi
  functionName: string
  args?: readonly unknown[]
}

const call = (address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []): ContractCall => ({
  address,
  abi,
  functionName,
  args,
})

const mkt = (fn: string, args?: readonly unknown[]) => call(A.serviceMarketplace, serviceMarketplaceAbi, fn, args)
const reg = (fn: string, args?: readonly unknown[]) => call(A.providerRegistry, providerRegistryAbi, fn, args)

export const calls = {
  // USDC approvals: exact amounts only, never unlimited.
  approveMarketplace: (amount: bigint) => call(A.usdc, erc20Abi, 'approve', [A.serviceMarketplace, amount]),
  approveRegistry: (amount: bigint) => call(A.usdc, erc20Abi, 'approve', [A.providerRegistry, amount]),

  // Buyer
  createRequest: (p: {
    directedProvider: Address
    serviceType: Hex
    locationHash: Hex
    price: bigint
    acceptDeadline: bigint
    serviceDeadline: bigint
  }) =>
    mkt('createRequest', [
      p.directedProvider,
      p.serviceType,
      p.locationHash,
      p.price,
      p.acceptDeadline,
      p.serviceDeadline,
    ]),
  cancelRequest: (id: bigint) => mkt('cancelRequest', [id]),
  confirmCompletion: (id: bigint) => mkt('confirmCompletion', [id]),

  // Provider (request lifecycle)
  acceptRequest: (id: bigint) => mkt('acceptRequest', [id]),
  startService: (id: bigint) => mkt('startService', [id]),
  submitProof: (id: bigint, evidenceCommitment: Hex) => mkt('submitProof', [id, evidenceCommitment]),

  // Parties and liveness exits
  openDispute: (id: bigint, reasonHash: Hex) => mkt('openDispute', [id, reasonHash]),
  expireRequest: (id: bigint) => mkt('expireRequest', [id]),
  closeUnreviewed: (id: bigint) => mkt('closeUnreviewed', [id]),
  resolveDisputeByTimeout: (id: bigint) => mkt('resolveDisputeByTimeout', [id]),

  // Verifier
  approveProof: (id: bigint) => mkt('approveProof', [id]),
  rejectProof: (id: bigint, reasonHash: Hex) => mkt('rejectProof', [id, reasonHash]),
  resolveDispute: (id: bigint, resolution: Resolution) => mkt('resolveDispute', [id, resolution]),
  verifyProvider: (provider: Address) => reg('verifyProvider', [provider]),
  revokeVerification: (provider: Address) => reg('revokeVerification', [provider]),

  // Provider (registry)
  register: (metadataHash: Hex, locationHash: Hex, capabilities: Hex[], stake: bigint) =>
    reg('register', [metadataHash, locationHash, capabilities, stake]),
  activate: () => reg('activate'),
  deactivate: () => reg('deactivate'),
  addCapability: (serviceType: Hex) => reg('addCapability', [serviceType]),
  removeCapability: (serviceType: Hex) => reg('removeCapability', [serviceType]),
  depositStake: (amount: bigint) => reg('depositStake', [amount]),
  requestUnstake: () => reg('requestUnstake'),
  withdrawStake: () => reg('withdrawStake'),

  // Escrow credit (refunds and earnings). Never paused.
  withdrawCredit: () => call(A.clinovaEscrow, clinovaEscrowAbi, 'withdraw'),
}
