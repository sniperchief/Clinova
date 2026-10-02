import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { providerLabel } from '../lib/providerLabel'
import { RequestStatusBadge } from '../components/Request'
import { EvidenceCheck } from '../components/RequestActions'
import { TxButton } from '../components/Tx'
import { Addr, Empty, Hash, ServiceName, Skeleton, Usdc } from '../components/ui'
import { NetworkGate } from '../components/Wallet'
import { useAccountState, useEvents, useProviders, useRequests } from '../hooks/useClinova'
import { calls } from '../lib/contracts/calls'
import { eventsForRequest } from '../lib/contracts/reads'
import { outcomeSummary } from '../lib/contracts/requestActions'
import { isTerminal, ProofStatus, Status, type RequestRecord } from '../lib/contracts/types'
import { formatDateTime, formatRelative, isZeroAddress, sameAddress } from '../lib/format'

export function Verifier() {
  const { address } = useAccount()
  const account = useAccountState()

  if (!address)
    return (
      <div className="container page">
        <Head />
        <NetworkGate>{null}</NetworkGate>
      </div>
    )
  if (!account.data)
    return (
      <div className="container page">
        <Skeleton height={300} />
      </div>
    )
  if (!account.data.isMarketplaceVerifier && !account.data.isRegistryVerifier)
    return (
      <div className="container page">
        <Head />
        <Empty>
          This dashboard is for wallets that hold Clinova’s verifier role. The connected wallet does not. Role checks here
          are for convenience only — the contracts enforce who can verify.
        </Empty>
      </div>
    )
  return (
    <div className="container page">
      <Head />
      <VerifierBoard canReview={account.data.isMarketplaceVerifier} canVerifyProviders={account.data.isRegistryVerifier} />
    </div>
  )
}

function Head() {
  return (
    <div className="page-head">
      <div>
        <span className="eyebrow">Verifier</span>
        <h1>Verification queue</h1>
        <p>
          Review provider profiles and proof of service, and resolve disputes. You can never review a request where you are
          the buyer or the provider.
        </p>
      </div>
    </div>
  )
}

function Party({ rec, address }: { rec: RequestRecord; address?: string }) {
  if (sameAddress(rec.request.buyer, address) || sameAddress(rec.request.provider, address))
    return <span className="chip" style={{ color: 'var(--warn)' }}>You are a party — another verifier must act</span>
  return null
}

function VerifierBoard({ canReview, canVerifyProviders }: { canReview: boolean; canVerifyProviders: boolean }) {
  const { address } = useAccount()
  const requests = useRequests().data
  const providers = useProviders().data
  const events = useEvents().data

  const pendingProviders = (providers ?? []).filter((p) => p.record.registered && !p.record.verified && p.record.unstakeAvailableAt === 0n)
  const verifiedProviders = (providers ?? []).filter((p) => p.record.verified)
  const pendingProofs = (requests ?? []).filter((r) => r.request.status === Status.COMPLETED)
  const disputes = (requests ?? []).filter((r) => r.request.status === Status.DISPUTED)
  const resolved = (requests ?? [])
    .filter(
      (r) =>
        isTerminal(r.request.status) &&
        (r.request.disputedFrom !== Status.NONE || r.proof.status === ProofStatus.APPROVED || r.proof.status === ProofStatus.REJECTED),
    )
    .sort((a, b) => Number(b.id - a.id))
    .slice(0, 10)

  return (
    <>
      <div className="grid grid-4">
        {[
          ['Providers to verify', pendingProviders.length],
          ['Pending proof reviews', pendingProofs.length],
          ['Active disputes', disputes.length],
          ['Recently resolved', resolved.length],
        ].map(([label, n]) => (
          <div key={label} className="card stat">
            <div className="label">{label}</div>
            <div className="value">{requests ? n : <Skeleton width={30} height={32} />}</div>
          </div>
        ))}
      </div>

      <section className="section">
        <div className="section-title">
          <h2>Pending proof reviews</h2>
          <span className="faint" style={{ fontSize: 13 }}>Check the evidence package before approving</span>
        </div>
        {!requests ? (
          <Skeleton height={100} />
        ) : pendingProofs.length === 0 ? (
          <Empty>No proofs are waiting for review.</Empty>
        ) : (
          <div className="grid grid-2">
            {pendingProofs.map((rec) => {
              const party = sameAddress(rec.request.buyer, address) || sameAddress(rec.request.provider, address)
              return (
                <div key={rec.id.toString()} className="card stack">
                  <RequestSummary rec={rec} />
                  <Party rec={rec} address={address} />
                  {!party && <EvidenceCheck rec={rec} />}
                  {canReview && !party && (
                    <div className="row">
                      <TxButton call={calls.approveProof(rec.id)} confirm="Approve this proof and release payment to the provider?">
                        Approve
                      </TxButton>
                      <Link to={`/requests/${rec.id}`} className="btn btn-danger">
                        Reject…
                      </Link>
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </section>

      <section className="section">
        <div className="section-title">
          <h2>Active disputes</h2>
        </div>
        {!requests ? (
          <Skeleton height={100} />
        ) : disputes.length === 0 ? (
          <Empty>No open disputes.</Empty>
        ) : (
          <div className="grid grid-2">
            {disputes.map((rec) => (
              <div key={rec.id.toString()} className="card stack">
                <RequestSummary rec={rec} />
                <span className="muted" style={{ fontSize: 14 }}>
                  Disputed from “{rec.request.disputedFrom === Status.COMPLETED ? 'proof submitted' : rec.request.disputedFrom === Status.IN_SERVICE ? 'in service' : 'accepted'}” ·
                  decide by {formatDateTime(rec.request.disputeDeadline)} ({formatRelative(rec.request.disputeDeadline)})
                </span>
                <Party rec={rec} address={address} />
                {canReview && !sameAddress(rec.request.buyer, address) && !sameAddress(rec.request.provider, address) && (
                  <Link to={`/requests/${rec.id}`} className="btn btn-primary" style={{ alignSelf: 'flex-start' }}>
                    Resolve dispute
                  </Link>
                )}
              </div>
            ))}
          </div>
        )}
      </section>

      <section className="section">
        <div className="section-title">
          <h2>Providers awaiting verification</h2>
          <span className="faint" style={{ fontSize: 13 }}>Verify only after checking the provider’s profile and licences offchain</span>
        </div>
        {!providers ? (
          <Skeleton height={80} />
        ) : pendingProviders.length === 0 ? (
          <Empty>No providers are waiting for verification.</Empty>
        ) : (
          <div className="card">
            <ProviderRows providers={pendingProviders} action="verify" enabled={canVerifyProviders} self={address} />
          </div>
        )}
      </section>

      <section className="section">
        <div className="section-title">
          <h2>Recently resolved</h2>
        </div>
        {!requests ? (
          <Skeleton height={80} />
        ) : resolved.length === 0 ? (
          <Empty>Nothing resolved yet.</Empty>
        ) : (
          <div className="card">
            <ul className="feed">
              {resolved.map((rec) => (
                <li key={rec.id.toString()}>
                  <Link to={`/requests/${rec.id}`} className="link">
                    #{rec.id.toString()} <ServiceName hash={rec.request.serviceType} short />
                  </Link>
                  <span className="muted">{outcomeSummary(rec, events ? eventsForRequest(events, rec.id) : [])}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </section>

      {verifiedProviders.length > 0 && (
        <details className="section">
          <summary className="link" style={{ cursor: 'pointer', display: 'inline-block' }}>
            Verified providers ({verifiedProviders.length})
          </summary>
          <div className="card" style={{ marginTop: 16 }}>
            <ProviderRows providers={verifiedProviders} action="revoke" enabled={canVerifyProviders} self={address} />
          </div>
        </details>
      )}
    </>
  )
}

function RequestSummary({ rec }: { rec: RequestRecord }) {
  return (
    <>
      <div className="spread">
        <Link to={`/requests/${rec.id}`} className="link" style={{ fontSize: 18 }}>
          #{rec.id.toString()} · <ServiceName hash={rec.request.serviceType} />
        </Link>
        <RequestStatusBadge rec={rec} />
      </div>
      <dl className="kv">
        <dt>Provider</dt>
        <dd>{isZeroAddress(rec.request.provider) ? '—' : <Addr address={rec.request.provider} />}</dd>
        <dt>Buyer</dt>
        <dd>
          <Addr address={rec.request.buyer} />
        </dd>
        <dt>Payment</dt>
        <dd>
          <Usdc amount={rec.request.price} />
        </dd>
        <dt>Proof commitment</dt>
        <dd>{rec.proof.status === ProofStatus.NONE ? <span className="faint">None submitted</span> : <Hash value={rec.proof.evidenceCommitment} />}</dd>
        {rec.request.status === Status.COMPLETED && (
          <>
            <dt>Review window</dt>
            <dd>Closes {formatRelative(rec.request.reviewDeadline)}</dd>
          </>
        )}
      </dl>
    </>
  )
}

function ProviderRows({
  providers,
  action,
  enabled,
  self,
}: {
  providers: NonNullable<ReturnType<typeof useProviders>['data']>
  action: 'verify' | 'revoke'
  enabled: boolean
  self?: string
}) {
  return (
    <div className="table-wrap">
      <table className="table table-cards">
        <thead>
          <tr>
            <th>Provider</th>
            <th>Services claimed</th>
            <th>Stake</th>
            <th>Registered</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {providers.map((p) => {
            const isSelf = sameAddress(p.address, self)
            return (
              <tr key={p.address}>
                <td className="cell-title" data-label="Provider">
                  <Addr address={p.address} label={providerLabel(p).name} />
                </td>
                <td data-label="Services">
                  <span className="row" style={{ gap: 6 }}>
                    {p.capabilities.map((c) => (
                      <span key={c} className="chip">
                        <ServiceName hash={c} short />
                      </span>
                    ))}
                  </span>
                </td>
                <td data-label="Stake">
                  <Usdc amount={p.record.stake} />
                </td>
                <td className="faint" data-label="Registered">block {p.registeredAt?.blockNumber.toString()}</td>
                <td className="cell-action" style={{ textAlign: 'right' }}>
                  {isSelf ? (
                    <span className="faint">Your own account</span>
                  ) : action === 'verify' ? (
                    <TxButton call={calls.verifyProvider(p.address)} variant="small" disabled={!enabled}>
                      Verify
                    </TxButton>
                  ) : (
                    <TxButton
                      call={calls.revokeVerification(p.address)}
                      variant="small"
                      disabled={!enabled}
                      confirm="Revoke this provider’s verification? It will stop receiving new requests."
                    >
                      Revoke
                    </TxButton>
                  )}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
