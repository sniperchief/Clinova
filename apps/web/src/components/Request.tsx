import { useNavigate } from 'react-router-dom'
import type { ClinovaEvent } from '../lib/contracts/reads'
import { nextDeadline } from '../lib/contracts/requestActions'
import { ProofStatus, Status, STATUS_LABEL, type RequestRecord } from '../lib/contracts/types'
import { formatDateTime, formatRelative, isZeroAddress, nowSeconds } from '../lib/format'
import { Addr, Badge, ServiceName, TxLink, Usdc } from './ui'

const TONE: Partial<Record<Status, 'ok' | 'progress' | 'warn' | 'bad'>> = {
  [Status.OPEN]: 'progress',
  [Status.ACCEPTED]: 'progress',
  [Status.IN_SERVICE]: 'progress',
  [Status.COMPLETED]: 'progress',
  [Status.DISPUTED]: 'warn',
  [Status.SETTLED]: 'ok',
}

export function RequestStatusBadge({ rec }: { rec: RequestRecord }) {
  const s = rec.request.status
  let label = STATUS_LABEL[s]
  if (s === Status.COMPLETED) label = 'Proof submitted · awaiting review'
  if (s === Status.DISPUTED) label = 'Disputed · awaiting verifier'
  if (s === Status.OPEN && nowSeconds() > rec.request.acceptDeadline) label = 'Acceptance window closed'
  return <Badge tone={TONE[s]}>{label}</Badge>
}

export function RequestTable({ requests, perspective }: { requests: RequestRecord[]; perspective: 'buyer' | 'provider' | 'verifier' }) {
  const navigate = useNavigate()
  return (
    <div className="table-wrap">
      <table className="table table-cards">
        <thead>
          <tr>
            <th>#</th>
            <th>Service</th>
            <th>{perspective === 'buyer' ? 'Provider' : 'Buyer'}</th>
            <th>Payment</th>
            <th>Status</th>
            <th>Next deadline</th>
          </tr>
        </thead>
        <tbody>
          {requests.map((rec) => {
            const d = nextDeadline(rec)
            const counterparty = perspective === 'buyer' ? rec.request.provider : rec.request.buyer
            return (
              <tr key={rec.id.toString()} className="clickable" onClick={() => navigate(`/requests/${rec.id}`)}>
                <td className="mono cell-id" data-label="Request">#{rec.id.toString()}</td>
                <td className="cell-title" data-label="Service">
                  <ServiceName hash={rec.request.serviceType} short />
                </td>
                <td data-label={perspective === 'buyer' ? 'Provider' : 'Buyer'} onClick={(e) => e.stopPropagation()}>
                  {isZeroAddress(counterparty) ? <span className="faint">Open to any provider</span> : <Addr address={counterparty} />}
                </td>
                <td data-label="Payment">
                  <Usdc amount={rec.request.price} />
                </td>
                <td data-label="Status">
                  <RequestStatusBadge rec={rec} />
                </td>
                <td className="muted" data-label="Next deadline" style={{ whiteSpace: 'nowrap' }}>
                  {d ? `${d.label} ${formatRelative(d.at)}` : '—'}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

interface Step {
  title: string
  state: 'done' | 'now' | 'todo' | 'bad'
  meta?: string
  event?: ClinovaEvent
}

const findEvent = (events: ClinovaEvent[], ...names: string[]) => events.find((e) => names.includes(e.eventName))

/** Discover → Reserve → Escrow → Verify → Settle → Reputation, from onchain state and events. */
export function RequestTimeline({ rec, events }: { rec: RequestRecord; events: ClinovaEvent[] }) {
  const r = rec.request
  const s = r.status
  const accepted = !isZeroAddress(rec.deposit.payee)
  const created = findEvent(events, 'ServiceRequestCreated')
  const steps: Step[] = [
    {
      title: 'Request created and USDC escrowed',
      state: 'done',
      meta: formatDateTime(r.createdAt),
      event: created,
    },
  ]

  if (s === Status.CANCELLED) {
    steps.push({ title: 'Cancelled by buyer — escrow refunded', state: 'bad', event: findEvent(events, 'ServiceRequestCancelled') })
  } else if (s === Status.EXPIRED && !accepted) {
    steps.push({ title: 'No provider accepted in time — escrow refunded', state: 'bad', event: findEvent(events, 'ServiceRequestExpired') })
  } else {
    steps.push({
      title: accepted ? 'Provider accepted' : 'Waiting for a provider to accept',
      state: accepted ? 'done' : 'now',
      meta: accepted ? undefined : `Accept by ${formatDateTime(r.acceptDeadline)}`,
      event: findEvent(events, 'ServiceRequestAccepted'),
    })
    if (accepted) {
      const started = findEvent(events, 'ServiceRequestStarted')
      const proofSubmitted = rec.proof.status !== ProofStatus.NONE
      steps.push({
        title: 'Service started',
        state: started || proofSubmitted ? 'done' : s === Status.ACCEPTED ? 'now' : 'todo',
        meta: started || proofSubmitted ? undefined : `Service due ${formatDateTime(r.serviceDeadline)}`,
        event: started,
      })
      steps.push({
        title: 'Proof of service submitted',
        state: proofSubmitted ? 'done' : s === Status.IN_SERVICE ? 'now' : s === Status.EXPIRED ? 'bad' : 'todo',
        meta: proofSubmitted ? formatDateTime(rec.proof.submittedAt) : undefined,
        event: findEvent(events, 'ServiceRequestCompleted', 'DisputeEvidenceSubmitted'),
      })
      if (r.disputedFrom !== Status.NONE) {
        steps.push({
          title: 'Disputed',
          state: s === Status.DISPUTED ? 'now' : 'done',
          meta: s === Status.DISPUTED ? `Verifier decision due by ${formatDateTime(r.disputeDeadline)}` : undefined,
          event: findEvent(events, 'ServiceRequestDisputed'),
        })
      }
      const reviewed = rec.proof.status !== ProofStatus.NONE && rec.proof.status !== ProofStatus.SUBMITTED
      steps.push({
        title:
          rec.proof.status === ProofStatus.BUYER_ACCEPTED
            ? 'Buyer confirmed completion'
            : rec.proof.status === ProofStatus.APPROVED
              ? 'Verifier approved the proof'
              : rec.proof.status === ProofStatus.REJECTED
                ? 'Verifier rejected the proof'
                : rec.proof.status === ProofStatus.UNRESOLVED
                  ? 'Closed without review'
                  : 'Verification',
        state: reviewed ? (rec.proof.status === ProofStatus.REJECTED ? 'bad' : 'done') : s === Status.COMPLETED ? 'now' : 'todo',
        meta: s === Status.COMPLETED ? `Review window closes ${formatDateTime(r.reviewDeadline)}` : undefined,
        event: findEvent(events, 'ProofApproved', 'ProofRejected', 'ProofAcceptedByBuyer', 'ProofUnresolved'),
      })
      const settled = s === Status.SETTLED
      const refunded = s === Status.REFUNDED || s === Status.EXPIRED
      steps.push({
        title: settled ? 'Settled — USDC released to the provider' : refunded ? 'Refunded — USDC returned to the buyer' : 'Settlement',
        state: settled ? 'done' : refunded ? 'bad' : 'todo',
        event: findEvent(events, 'ServiceRequestSettled', 'ServiceRequestRefunded', 'ServiceRequestExpired'),
      })
      steps.push({
        title: 'Outcome added to the provider’s reputation',
        state: rec.outcomeRecorded ? 'done' : 'todo',
        event: findEvent(events, 'OutcomeRecorded'),
      })
    }
  }

  return (
    <ol className="timeline">
      {steps.map((st, i) => (
        <li key={i} className={st.state}>
          <span className="dot" />
          <div className="t-title">{st.title}</div>
          <div className="t-meta row" style={{ gap: 10 }}>
            {st.meta && <span>{st.meta}</span>}
            {st.event && <TxLink hash={st.event.transactionHash}>Transaction</TxLink>}
          </div>
        </li>
      ))}
    </ol>
  )
}
