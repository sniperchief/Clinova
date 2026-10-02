import type { Address, Hex } from 'viem'

/** Mirrors ClinovaTypes.sol. Numeric values must match the Solidity enum order. */
export const Status = {
  NONE: 0,
  OPEN: 1,
  ACCEPTED: 2,
  IN_SERVICE: 3,
  COMPLETED: 4,
  SETTLED: 5,
  CANCELLED: 6,
  EXPIRED: 7,
  DISPUTED: 8,
  REFUNDED: 9,
} as const
export type Status = (typeof Status)[keyof typeof Status]

export const ProofStatus = {
  NONE: 0,
  SUBMITTED: 1,
  APPROVED: 2,
  REJECTED: 3,
  BUYER_ACCEPTED: 4,
  UNRESOLVED: 5,
} as const
export type ProofStatus = (typeof ProofStatus)[keyof typeof ProofStatus]

export const EscrowState = { NONE: 0, FUNDED: 1, RELEASED: 2, REFUNDED: 3 } as const
export type EscrowState = (typeof EscrowState)[keyof typeof EscrowState]

export const Resolution = { PROVIDER_WINS: 0, REFUND_PROVIDER_FAULT: 1, REFUND_NO_FAULT: 2 } as const
export type Resolution = (typeof Resolution)[keyof typeof Resolution]

export const SettlementPath = { BUYER_CONFIRMED: 0, VERIFIER_APPROVED: 1, DISPUTE_RESOLVED: 2 } as const

export interface ServiceRequest {
  buyer: Address
  createdAt: bigint
  status: Status
  disputedFrom: Status
  provider: Address
  acceptDeadline: bigint
  serviceType: Hex
  locationHash: Hex
  price: bigint
  serviceDeadline: bigint
  reviewPeriod: number
  disputePeriod: number
  reviewDeadline: bigint
  disputeDeadline: bigint
}

export interface Deposit {
  payer: Address
  amount: bigint
  state: EscrowState
  payee: Address
}

export interface ServiceProof {
  provider: Address
  submittedAt: bigint
  status: ProofStatus
  reviewer: Address
  reviewedAt: bigint
  evidenceCommitment: Hex
  proofHash: Hex
}

export interface ProviderRecord {
  metadataHash: Hex
  locationHash: Hex
  stake: bigint
  unstakeAvailableAt: bigint
  activeJobs: number
  registered: boolean
  verified: boolean
  active: boolean
}

export interface Reputation {
  completedJobs: bigint
  successfulJobs: bigint
  failedJobs: bigint
  disputes: bigint
}

/** One request with its escrow deposit and proof, read together in a single multicall. */
export interface RequestRecord {
  id: bigint
  request: ServiceRequest
  deposit: Deposit
  proof: ServiceProof
  outcomeRecorded: boolean
}

export const TERMINAL: readonly Status[] = [Status.SETTLED, Status.CANCELLED, Status.EXPIRED, Status.REFUNDED]
export const isTerminal = (s: Status) => TERMINAL.includes(s)

export const STATUS_LABEL: Record<Status, string> = {
  [Status.NONE]: 'Not found',
  [Status.OPEN]: 'Awaiting provider',
  [Status.ACCEPTED]: 'Accepted',
  [Status.IN_SERVICE]: 'In service',
  [Status.COMPLETED]: 'Proof submitted',
  [Status.SETTLED]: 'Settled',
  [Status.CANCELLED]: 'Cancelled',
  [Status.EXPIRED]: 'Expired',
  [Status.DISPUTED]: 'Disputed',
  [Status.REFUNDED]: 'Refunded',
}

export const PROOF_LABEL: Record<ProofStatus, string> = {
  [ProofStatus.NONE]: 'No proof yet',
  [ProofStatus.SUBMITTED]: 'Awaiting review',
  [ProofStatus.APPROVED]: 'Approved by verifier',
  [ProofStatus.REJECTED]: 'Rejected by verifier',
  [ProofStatus.BUYER_ACCEPTED]: 'Accepted by buyer',
  [ProofStatus.UNRESOLVED]: 'Closed unreviewed',
}

export const ESCROW_LABEL: Record<EscrowState, string> = {
  [EscrowState.NONE]: 'Not funded',
  [EscrowState.FUNDED]: 'Held in escrow',
  [EscrowState.RELEASED]: 'Released to provider',
  [EscrowState.REFUNDED]: 'Refunded to buyer',
}

export const RESOLUTION_LABEL: Record<Resolution, string> = {
  [Resolution.PROVIDER_WINS]: 'Provider paid',
  [Resolution.REFUND_PROVIDER_FAULT]: 'Buyer refunded (provider at fault)',
  [Resolution.REFUND_NO_FAULT]: 'Buyer refunded (no fault)',
}
