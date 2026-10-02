import { Link, useParams } from 'react-router-dom'
import { useConnection } from 'wagmi'
import { RequestStatusBadge, RequestTimeline } from '../components/Request'
import { EvidenceCheck, RequestActions } from '../components/RequestActions'
import { Addr, Empty, Hash, LoadError, RegionName, ServiceName, Skeleton, TxLink, Usdc } from '../components/ui'
import { useAccountState, useEvents, useProviders, useRequest } from '../hooks/useClinova'
import { providerLabel } from '../lib/providerLabel'
import { describeEvent } from '../lib/activity'
import { eventsForRequest } from '../lib/contracts/reads'
import { outcomeSummary, roleIn } from '../lib/contracts/requestActions'
import { ESCROW_LABEL, PROOF_LABEL, ProofStatus, Status } from '../lib/contracts/types'
import { formatDateTime, formatDuration, isZeroAddress } from '../lib/format'

const ROLE_TEXT = {
  buyer: 'You created this request',
  provider: 'You are the provider on this request',
  verifier: 'You are viewing as a verifier',
  observer: 'You are viewing this request',
}

export function RequestDetail() {
  const { id: idParam } = useParams()
  const id = idParam && /^\d+$/.test(idParam) ? BigInt(idParam) : null
  const { address } = useConnection()
  const request = useRequest(id)
  const events = useEvents().data
  const account = useAccountState().data
  const isVerifier = !!account?.isMarketplaceVerifier
  const providers = useProviders().data

  if (id === null) return <div className="container page"><Empty>Invalid request id.</Empty></div>
  if (request.error) return <div className="container page"><LoadError error={request.error} /></div>
  const rec = request.data
  if (!rec)
    return (
      <div className="container page stack">
        <Skeleton width={240} height={44} />
        <Skeleton height={300} />
      </div>
    )
  if (rec.request.status === Status.NONE)
    return (
      <div className="container page">
        <Empty>Request #{id.toString()} does not exist.</Empty>
      </div>
    )

  const r = rec.request
  const reqEvents = events ? eventsForRequest(events, id) : []
  const role = roleIn(rec, address, isVerifier)
  const outcome = outcomeSummary(rec, reqEvents)
  const isParty = role === 'buyer' || role === 'provider'
  const providerView = providers?.find((p) => p.address.toLowerCase() === r.provider.toLowerCase())
  const providerName = providerView ? providerLabel(providerView).name : undefined
  // Only the business-level steps; internal module bookkeeping (escrow locks, job records) stays on Arbiscan.
  const activity = reqEvents.flatMap((e) => {
    const text = describeEvent(e)
    return text ? [{ e, text }] : []
  })

  return (
    <div className="container page">
      <div className="page-head">
        <div>
          <Link to={role === 'provider' ? '/provider' : role === 'verifier' ? '/verifier' : '/buyer'} className="link">
            ← Back
          </Link>
          <h1 style={{ marginTop: 16 }}>
            <ServiceName hash={r.serviceType} /> <span className="faint">#{id.toString()}</span>
          </h1>
          <div className="row" style={{ marginTop: 12 }}>
            <RequestStatusBadge rec={rec} />
            {outcome && <span className="muted">{outcome}</span>}
          </div>
        </div>
        <div className="stat head-amount">
          <div className="label">Payment</div>
          <div className="value">
            <Usdc amount={r.price} unit={false} />
            <small>USDC</small>
          </div>
          <div className="hint">{ESCROW_LABEL[rec.deposit.state]}</div>
        </div>
      </div>

      <div className="split detail-split">
        <div className="stack">
          <div className="card">
            <div className="section-title">
              <h2 style={{ fontSize: 20 }}>Progress</h2>
              <span className="faint" style={{ fontSize: 13 }}>
                Discover → Reserve → Escrow → Verify → Settle → Reputation
              </span>
            </div>
            <RequestTimeline rec={rec} events={reqEvents} />
          </div>

          <div className="card">
            <h3 style={{ marginBottom: 16 }}>Details</h3>
            <dl className="kv">
              <dt>Buyer</dt>
              <dd>
                <Addr address={r.buyer} />
              </dd>
              <dt>Provider</dt>
              <dd>
                {isZeroAddress(r.provider) ? (
                  <span className="faint">Open to any eligible provider</span>
                ) : (
                  <>
                    <Addr address={r.provider} label={providerName} />
                    {r.status === Status.OPEN && <span className="faint"> (directed; not yet accepted)</span>}
                  </>
                )}
              </dd>
              <dt>Service area</dt>
              <dd>
                <RegionName hash={r.locationHash} />
              </dd>
              <dt>Escrow</dt>
              <dd>
                {ESCROW_LABEL[rec.deposit.state]} · <Usdc amount={rec.deposit.amount} />
              </dd>
              <dt>Created</dt>
              <dd>{formatDateTime(r.createdAt)}</dd>
              <dt>Accept by</dt>
              <dd>{formatDateTime(r.acceptDeadline)}</dd>
              <dt>Service by</dt>
              <dd>{formatDateTime(r.serviceDeadline)}</dd>
              <dt>Review window</dt>
              <dd>
                {r.reviewDeadline > 0n ? `Until ${formatDateTime(r.reviewDeadline)}` : `${formatDuration(r.reviewPeriod)} after proof`}
              </dd>
              {r.disputeDeadline > 0n && (
                <>
                  <dt>Dispute deadline</dt>
                  <dd>{formatDateTime(r.disputeDeadline)}</dd>
                </>
              )}
            </dl>
          </div>

          <div className="card">
            <h3 style={{ marginBottom: 6 }}>Proof of service</h3>
            <p className="faint" style={{ margin: '0 0 16px', fontSize: 13 }}>
              Clinova stores a salted cryptographic commitment to the provider’s evidence — never the evidence or any
              patient information.
            </p>
            {rec.proof.status === ProofStatus.NONE ? (
              <span className="muted">No proof submitted yet.</span>
            ) : (
              <dl className="kv">
                <dt>Status</dt>
                <dd>{PROOF_LABEL[rec.proof.status]}</dd>
                <dt>Submitted</dt>
                <dd>{formatDateTime(rec.proof.submittedAt)}</dd>
                <dt>Evidence commitment</dt>
                <dd>
                  <Hash value={rec.proof.evidenceCommitment} />
                </dd>
                <dt>Proof hash</dt>
                <dd>
                  <Hash value={rec.proof.proofHash} />{' '}
                  <span className="faint" style={{ fontSize: 12 }}>
                    bound onchain to this chain, contract, request and provider
                  </span>
                </dd>
                {!isZeroAddress(rec.proof.reviewer) && (
                  <>
                    <dt>Reviewed by</dt>
                    <dd>
                      <Addr address={rec.proof.reviewer} /> · {formatDateTime(rec.proof.reviewedAt)}
                    </dd>
                  </>
                )}
              </dl>
            )}
          </div>
        </div>

        <div className="stack">
          <div className="card elevated">
            <span className="eyebrow">{address ? ROLE_TEXT[role] : 'Actions'}</span>
            {isVerifier && isParty && (
              <p className="notice" style={{ marginTop: 12 }}>
                You hold the verifier role but are a party to this request, so the contracts will not let you review it.
              </p>
            )}
            <div style={{ marginTop: 16 }}>
              <RequestActions rec={rec} />
            </div>
          </div>

          {isVerifier && !isParty && rec.proof.status === ProofStatus.SUBMITTED && (
            <div className="card">
              <EvidenceCheck rec={rec} />
            </div>
          )}

          <div className="card">
            <h3 style={{ marginBottom: 12 }}>Onchain activity</h3>
            {!events ? (
              <Skeleton height={80} />
            ) : activity.length === 0 ? (
              <span className="faint">No events found.</span>
            ) : (
              <ul className="feed">
                {activity.map(({ e, text }) => (
                  <li key={`${e.transactionHash}-${e.logIndex}`}>
                    <span className="muted">{text}</span>
                    <TxLink hash={e.transactionHash}>tx</TxLink>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
