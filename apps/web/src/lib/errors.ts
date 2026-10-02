import {
  BaseError,
  ChainMismatchError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
} from 'viem'
import { formatDateTime, usdc } from './format'
import { STATUS_LABEL, type Status } from './contracts/types'

export interface FriendlyError {
  message: string
  technical: string
}

type Explainer = (args: readonly unknown[]) => string

/** Known custom errors from the five Clinova contracts, in plain language. */
const CUSTOM_ERRORS: Record<string, Explainer> = {
  // Marketplace
  InvalidStatus: (a) =>
    `This request is now “${STATUS_LABEL[Number(a[1]) as Status] ?? 'in another state'}”, which does not allow this action. It may already be settled or have moved on — refresh to see the latest state.`,
  NotBuyer: () => 'Only the healthcare business that created this request can do this.',
  NotAssignedProvider: () => 'Only the provider assigned to this request can do this.',
  NotParty: () => 'Only the buyer or the assigned provider can do this.',
  BuyerCannotAccept: () => 'A buyer cannot accept or be directed its own request. Use a different wallet.',
  ConflictOfInterest: () => 'You are a party to this request, so you cannot review it. Another verifier must act.',
  PriceTooLow: (a) => `The payment is below the protocol minimum of ${usdc(a[1] as bigint)}.`,
  InvalidDeadlines: () =>
    'The deadlines are outside the allowed windows (accept within 1 hour to 7 days; service at least 6 hours and at most 30 days after that).',
  DeadlinePassed: (a) => `The deadline for this step passed on ${formatDateTime(a[0] as bigint)}.`,
  DeadlineNotPassed: (a) => `This is only available after ${formatDateTime(a[0] as bigint)}.`,
  InvalidServiceType: () => 'Choose a diagnostic service.',
  InvalidHash: () => 'A required reference is missing.',
  ProofNotApprovable: () => 'The proof is no longer under review, so the provider cannot be paid through this dispute.',
  TransferAmountMismatch: () => 'The token transfer did not deliver the expected amount.',
  EnforcedPause: () => 'Clinova is temporarily paused. New requests and job acceptances are unavailable.',
  // Registry
  ProviderNotEligible: () =>
    'This provider is not currently eligible for this request (it must be verified, active, staked and offer the service).',
  ProviderAlreadyRegistered: () => 'This wallet is already registered as a provider.',
  ProviderNotFound: () => 'This wallet is not registered as a provider.',
  ProviderAlreadyVerified: () => 'This provider is already verified.',
  ProviderNotVerified: () => 'The provider must be verified before it can be activated.',
  ProviderAlreadyActive: () => 'The provider is already active.',
  ProviderInactive: () => 'The provider is not active.',
  CapabilityAlreadyAdded: () => 'This service is already listed.',
  CapabilityNotFound: () => 'This service is not listed.',
  InvalidCapability: () => 'Choose at least one valid service, without duplicates.',
  InsufficientStake: (a) => `The stake is below the required minimum of ${usdc(a[1] as bigint)}.`,
  ZeroAmount: () => 'Enter an amount greater than zero.',
  NoStake: () => 'There is no stake to unbond.',
  UnstakePending: (a) => `Stake is unbonding until ${formatDateTime(a[0] as bigint)}.`,
  NoUnstakeRequested: () => 'Request to unstake first; withdrawal opens after the unbonding period.',
  UnstakeNotReady: (a) => `Stake can be withdrawn after ${formatDateTime(a[0] as bigint)}.`,
  ActiveObligation: (a) => `The provider still has ${String(a[0])} active job(s). Close them before withdrawing stake.`,
  SelfVerification: () => 'A verifier cannot verify its own provider account.',
  MarketplaceCannotBeProvider: () => 'This address cannot register as a provider.',
  // Proof of service
  InvalidCommitment: () => 'The evidence commitment is empty.',
  ProofAlreadySubmitted: () => 'A proof has already been submitted for this request.',
  EvidenceAlreadyUsed: () => 'This evidence was already used for another request. Each request needs its own evidence.',
  ProofNotReviewable: () => 'This proof has already been reviewed.',
  NotVerifier: () => 'Your wallet does not hold the verifier role.',
  // Escrow
  NothingToWithdraw: () => 'There is nothing to withdraw. Funds may already have been withdrawn.',
  InvalidRecipient: () => 'Funds cannot be sent to that address.',
  // Access control
  AccessControlUnauthorizedAccount: () => 'Your wallet does not hold the role required for this action.',
  // OpenZeppelin SafeERC20
  SafeERC20FailedOperation: () => 'The USDC transfer failed. Check your USDC balance and approval.',
}

/** Circle's FiatToken reverts with strings, not custom errors. */
const REVERT_REASONS: [RegExp, string][] = [
  [/exceeds balance/i, 'Not enough USDC in this wallet.'],
  [/exceeds allowance/i, 'USDC is not approved for this amount yet. Approve it first.'],
  [/blacklisted/i, 'This account cannot send or receive USDC.'],
  [/paused/i, 'USDC transfers are paused by the token issuer.'],
]

export function describeError(err: unknown): FriendlyError {
  const technical = err instanceof BaseError ? err.shortMessage + (err.details ? `\n${err.details}` : '') : String(err)
  const full = err instanceof Error ? err.message : String(err)
  if (!(err instanceof BaseError)) return { message: 'Something went wrong. Please try again.', technical: full }

  if (err.walk((e) => e instanceof UserRejectedRequestError) || /user (rejected|denied)/i.test(full))
    return { message: 'You cancelled the request in your wallet. Nothing was sent.', technical }
  if (err.walk((e) => e instanceof ChainMismatchError))
    return { message: 'Your wallet is on another network. Switch to Arbitrum Sepolia and try again.', technical }
  if (err.walk((e) => e instanceof InsufficientFundsError) || /insufficient funds/i.test(full))
    return {
      message: 'Not enough ETH on Arbitrum Sepolia to pay the network fee. Get test ETH from a faucet.',
      technical,
    }

  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError)
  if (reverted instanceof ContractFunctionRevertedError) {
    const name = reverted.data?.errorName
    if (name && CUSTOM_ERRORS[name])
      return { message: CUSTOM_ERRORS[name](reverted.data?.args ?? []), technical: `${name}(${fmtArgs(reverted.data?.args)})\n${technical}` }
    const reason = reverted.reason ?? ''
    for (const [re, msg] of REVERT_REASONS) if (re.test(reason)) return { message: msg, technical }
    if (name) return { message: `The contract rejected this action (${name}).`, technical }
    return { message: 'The contract rejected this action.', technical }
  }
  for (const [re, msg] of REVERT_REASONS) if (re.test(full)) return { message: msg, technical }
  return { message: err.shortMessage || 'Something went wrong. Please try again.', technical }
}

function fmtArgs(args?: readonly unknown[]) {
  return (args ?? []).map((a) => (typeof a === 'bigint' ? a.toString() : String(a))).join(', ')
}
