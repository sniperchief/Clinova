import { ProofStatus, Status, type RequestRecord } from './contracts/types'

export type Perspective = 'buyer' | 'provider'
export type Tone = 'ok' | 'info' | 'warn' | 'muted'

export interface JobState {
  /** Short status for the pill. */
  label: string
  tone: Tone
  /** What happens next, from this party's point of view. */
  next: string
  /** True when this party can act now (mirrors the contract's transition table). */
  actionNeeded: boolean
}

/** List-level summary of a request for one party. Detailed gating lives in requestActions.ts. */
export function jobState(rec: RecordLike, perspective: Perspective, now: bigint): JobState {
  const r = rec.request
  const pastAccept = now > r.acceptDeadline
  const pastService = now > r.serviceDeadline
  const buyer = perspective === 'buyer'

  switch (r.status) {
    case Status.OPEN:
      if (pastAccept)
        return { label: 'Window closed', tone: 'muted', next: buyer ? 'Close and reclaim payment' : 'No longer available', actionNeeded: buyer }
      return buyer
        ? { label: 'Awaiting provider', tone: 'info', next: 'Waiting for a provider to accept', actionNeeded: false }
        : { label: 'Open request', tone: 'info', next: 'Review and accept', actionNeeded: true }
    case Status.ACCEPTED:
    case Status.IN_SERVICE: {
      const started = r.status === Status.IN_SERVICE
      if (pastService)
        return { label: 'Deadline missed', tone: 'warn', next: buyer ? 'Claim refund' : 'Service deadline passed', actionNeeded: buyer }
      if (buyer)
        return { label: started ? 'In service' : 'Accepted', tone: 'info', next: started ? 'Service under way' : 'Provider preparing service', actionNeeded: false }
      return { label: started ? 'In service' : 'Accepted', tone: 'info', next: started ? 'Submit proof of service' : 'Start service', actionNeeded: true }
    }
    case Status.COMPLETED:
      return buyer
        ? { label: 'Proof submitted', tone: 'info', next: 'Review and confirm', actionNeeded: true }
        : { label: 'Awaiting review', tone: 'info', next: 'Buyer or verifier is reviewing', actionNeeded: false }
    case Status.DISPUTED: {
      const canAddEvidence =
        !buyer &&
        (r.disputedFrom === Status.ACCEPTED || r.disputedFrom === Status.IN_SERVICE) &&
        rec.proof.status === ProofStatus.NONE &&
        !pastService
      return {
        label: 'Disputed',
        tone: 'warn',
        next: canAddEvidence ? 'Submit evidence' : 'Awaiting verifier decision',
        actionNeeded: canAddEvidence,
      }
    }
    case Status.SETTLED:
      return { label: 'Settled', tone: 'ok', next: buyer ? 'Paid to provider' : 'Payment released to you', actionNeeded: false }
    case Status.REFUNDED:
      return { label: 'Refunded', tone: 'muted', next: 'Payment returned to buyer', actionNeeded: false }
    case Status.CANCELLED:
      return { label: 'Cancelled', tone: 'muted', next: 'Payment returned to buyer', actionNeeded: false }
    case Status.EXPIRED:
      return { label: 'Expired', tone: 'muted', next: 'Payment returned to buyer', actionNeeded: false }
    default:
      return { label: 'Unknown', tone: 'muted', next: '', actionNeeded: false }
  }
}

type RecordLike = Pick<RequestRecord, 'request' | 'proof'>

/** The deadline that matters next, for list rows. */
export function upcomingDeadline(rec: RecordLike): { label: string; at: bigint } | null {
  const r = rec.request
  switch (r.status) {
    case Status.OPEN:
      return { label: 'Accept by', at: r.acceptDeadline }
    case Status.ACCEPTED:
    case Status.IN_SERVICE:
      return { label: 'Service due', at: r.serviceDeadline }
    case Status.COMPLETED:
      return { label: 'Review closes', at: r.reviewDeadline }
    case Status.DISPUTED:
      return { label: 'Decision due', at: r.disputeDeadline }
    default:
      return null
  }
}
