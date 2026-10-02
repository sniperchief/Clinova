import type { Address, Hex } from 'viem'
import { isZeroAddress, sameAddress } from '../format'
import type { ClinovaEvent } from './reads'
import { ProofStatus, Resolution, Status, type RequestRecord } from './types'

/**
 * Mirrors the transition table in docs/contract-spec.md §1 so the UI only offers actions the contract would accept.
 * This is UX only: every action is also simulated against the live contract before the wallet is asked to sign,
 * and the contract remains the security boundary.
 */

export type ActionId =
  | 'cancel'
  | 'expireOpen'
  | 'accept'
  | 'start'
  | 'submitProof'
  | 'confirm'
  | 'dispute'
  | 'expireAccepted'
  | 'closeUnreviewed'
  | 'approveProof'
  | 'rejectProof'
  | 'resolveDispute'
  | 'disputeTimeout'

export interface ActionContext {
  account?: Address
  now: bigint
  isVerifier: boolean
  marketplacePaused: boolean
  /** Whether `account` is eligible in the registry for a service type. */
  isEligible: (serviceType: Hex) => boolean
}

export interface AvailableAction {
  id: ActionId
  /** If set, the action is shown but disabled with this explanation. */
  blockedReason?: string
}

export type Role = 'buyer' | 'provider' | 'verifier' | 'observer'

export function roleIn(rec: RequestRecord, account?: Address, isVerifier = false): Role {
  if (sameAddress(account, rec.request.buyer)) return 'buyer'
  if (!isZeroAddress(rec.request.provider) && sameAddress(account, rec.request.provider)) {
    // A directed-but-unaccepted request also names the provider.
    return 'provider'
  }
  if (isVerifier) return 'verifier'
  return 'observer'
}

export function availableActions(rec: RequestRecord, ctx: ActionContext): AvailableAction[] {
  const r = rec.request
  const { account, now } = ctx
  if (!account) return []
  const isBuyer = sameAddress(account, r.buyer)
  const isProvider = !isZeroAddress(r.provider) && sameAddress(account, r.provider)
  const isParty = isBuyer || isProvider
  const actions: AvailableAction[] = []

  switch (r.status) {
    case Status.OPEN: {
      if (isBuyer) actions.push({ id: 'cancel' })
      if (now > r.acceptDeadline) {
        actions.push({ id: 'expireOpen' })
        break
      }
      const directedElsewhere = !isZeroAddress(r.provider) && !isProvider
      if (!isBuyer && !directedElsewhere) {
        if (ctx.marketplacePaused) actions.push({ id: 'accept', blockedReason: 'Clinova is paused for new acceptances.' })
        else if (!ctx.isEligible(r.serviceType))
          actions.push({
            id: 'accept',
            blockedReason: 'Your provider account is not eligible for this service (verified, active, staked, offers it).',
          })
        else actions.push({ id: 'accept' })
      }
      break
    }
    case Status.ACCEPTED:
    case Status.IN_SERVICE: {
      const beforeService = now <= r.serviceDeadline
      if (isProvider && beforeService) actions.push({ id: r.status === Status.ACCEPTED ? 'start' : 'submitProof' })
      if (isParty && beforeService) actions.push({ id: 'dispute' })
      if (isParty && !beforeService) actions.push({ id: 'expireAccepted' })
      break
    }
    case Status.COMPLETED: {
      if (isBuyer) actions.push({ id: 'confirm' })
      if (isBuyer && now <= r.reviewDeadline) actions.push({ id: 'dispute' })
      if (ctx.isVerifier && !isParty) actions.push({ id: 'approveProof' }, { id: 'rejectProof' })
      if (now > r.reviewDeadline) actions.push({ id: 'closeUnreviewed' })
      break
    }
    case Status.DISPUTED: {
      const canAddEvidence =
        (r.disputedFrom === Status.ACCEPTED || r.disputedFrom === Status.IN_SERVICE) &&
        rec.proof.status === ProofStatus.NONE &&
        now <= r.serviceDeadline
      if (isProvider && canAddEvidence) actions.push({ id: 'submitProof' })
      if (ctx.isVerifier && !isParty) actions.push({ id: 'resolveDispute' })
      if (now > r.disputeDeadline) actions.push({ id: 'disputeTimeout' })
      break
    }
  }
  return actions
}

/** PROVIDER_WINS is only possible while a proof is still under review (spec T13). */
export const canResolveForProvider = (rec: RequestRecord) => rec.proof.status === ProofStatus.SUBMITTED

/** Plain-language outcome of a finished request, from onchain state and (when available) its events. */
export function outcomeSummary(rec: RequestRecord, events: ClinovaEvent[] = []): string | null {
  const r = rec.request
  const disputed = r.disputedFrom !== Status.NONE
  const resolved = events.find((e) => e.eventName === 'DisputeResolved')
  switch (r.status) {
    case Status.SETTLED:
      if (disputed) return 'Resolved — provider paid'
      if (rec.proof.status === ProofStatus.BUYER_ACCEPTED) return 'Settlement complete — buyer confirmed'
      return 'Settlement complete — verifier approved'
    case Status.REFUNDED:
      if (resolved) {
        const res = Number(resolved.args.resolution)
        return res === Resolution.REFUND_PROVIDER_FAULT
          ? 'Resolved — buyer refunded (provider at fault)'
          : 'Resolved — buyer refunded (no fault)'
      }
      if (events.some((e) => e.eventName === 'DisputeTimedOut')) return 'Dispute timed out — buyer refunded'
      if (events.some((e) => e.eventName === 'CompletionClosedUnreviewed'))
        return 'Closed unreviewed — buyer refunded'
      return disputed ? 'Resolved — buyer refunded' : 'Buyer refunded'
    case Status.CANCELLED:
      return 'Cancelled by buyer — refunded'
    case Status.EXPIRED:
      // The escrow payee is bound only at acceptance, so it tells the two expiry paths apart.
      return !isZeroAddress(rec.deposit.payee)
        ? 'Expired — provider missed the service deadline, buyer refunded'
        : 'Expired — no provider accepted, buyer refunded'
    default:
      return null
  }
}

/** The next deadline that matters for this request, for list views. */
export function nextDeadline(rec: RequestRecord): { label: string; at: bigint } | null {
  const r = rec.request
  switch (r.status) {
    case Status.OPEN:
      return { label: 'Accept by', at: r.acceptDeadline }
    case Status.ACCEPTED:
    case Status.IN_SERVICE:
      return { label: 'Service due', at: r.serviceDeadline }
    case Status.COMPLETED:
      return { label: 'Review by', at: r.reviewDeadline }
    case Status.DISPUTED:
      return { label: 'Dispute deadline', at: r.disputeDeadline }
    default:
      return null
  }
}
