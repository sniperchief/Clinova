import type { ClinovaEvent } from './contracts/reads'
import { RESOLUTION_LABEL, type Resolution } from './contracts/types'
import { usdc } from './format'

/** Plain-language description of protocol events for activity feeds. Unlisted events return null. */
export function describeEvent(e: ClinovaEvent): string | null {
  const a = e.args
  const id = a.id !== undefined ? `#${String(a.id)}` : ''
  switch (e.eventName) {
    case 'ServiceRequestCreated':
      return `Request ${id} created · ${usdc(a.price as bigint)} escrowed`
    case 'ServiceRequestAccepted':
      return `Request ${id} accepted by a provider`
    case 'ServiceRequestStarted':
      return `Service started on request ${id}`
    case 'ServiceRequestCompleted':
      return `Proof of service submitted for request ${id}`
    case 'ServiceRequestSettled':
      return `Request ${id} settled · ${usdc(a.amount as bigint)} released to provider`
    case 'ServiceRequestRefunded':
      return `Request ${id} refunded · ${usdc(a.amount as bigint)} to buyer`
    case 'ServiceRequestCancelled':
      return `Request ${id} cancelled by buyer`
    case 'ServiceRequestExpired':
      return `Request ${id} expired`
    case 'ServiceRequestDisputed':
      return `Request ${id} disputed`
    case 'ProofApproved':
      return 'Proof approved by a verifier'
    case 'ProofRejected':
      return 'Proof rejected by a verifier'
    case 'ProofAcceptedByBuyer':
      return 'Buyer confirmed completion'
    case 'OutcomeRecorded':
      return 'Outcome added to provider reputation'
    case 'DisputeResolved':
      return `Dispute on request ${id} resolved · ${RESOLUTION_LABEL[Number(a.resolution) as Resolution]}`
    case 'ProviderRegistered':
      return 'A new provider registered and staked'
    case 'ProviderVerified':
      return 'A provider was verified'
    case 'ProviderActivated':
      return 'A provider started accepting requests'
    case 'Withdrawal':
      return `${usdc(a.amount as bigint)} withdrawn from escrow`
    default:
      return null
  }
}

export function recentActivity(events: ClinovaEvent[], limit: number) {
  const out: { event: ClinovaEvent; text: string }[] = []
  for (let i = events.length - 1; i >= 0 && out.length < limit; i--) {
    const text = describeEvent(events[i])
    if (text) out.push({ event: events[i], text })
  }
  return out
}
