import { Link } from 'react-router-dom'
import type { ProviderView } from '../lib/contracts/reads'
import type { ProviderRecord, Reputation } from '../lib/contracts/types'
import { providerLabel } from '../lib/providerLabel'
import { formatDateTime, nowSeconds } from '../lib/format'
import { Addr, Badge, RegionName, ServiceName, Usdc } from './ui'

export function ProviderStatus({ record, minStake }: { record: ProviderRecord; minStake?: bigint }) {
  if (!record.registered) return <Badge>Not registered</Badge>
  if (record.unstakeAvailableAt > 0n)
    return <Badge tone="warn">Unbonding until {formatDateTime(record.unstakeAvailableAt)}</Badge>
  if (!record.verified) return <Badge tone="warn">Awaiting verification</Badge>
  if (minStake !== undefined && record.stake < minStake) return <Badge tone="warn">Stake below minimum</Badge>
  if (!record.active) return <Badge>Verified · not accepting requests</Badge>
  return <Badge tone="ok">Verified · accepting requests</Badge>
}

export function ReputationPanel({ reputation, compact }: { reputation: Reputation; compact?: boolean }) {
  const items: [string, bigint, string][] = [
    ['Completed', reputation.completedJobs, 'Jobs where the provider submitted proof of service'],
    ['Successful', reputation.successfulJobs, 'Jobs that settled with payment to the provider'],
    ['Failed', reputation.failedJobs, 'Jobs where the provider was found at fault or missed its deadline'],
    ['Disputed', reputation.disputes, 'Jobs that were contested. Not a fault count'],
  ]
  return (
    <div className={`grid ${compact ? 'grid-4' : 'grid-4'}`} style={{ gap: compact ? 8 : 16 }}>
      {items.map(([label, value, help]) => (
        <div key={label} title={help} style={compact ? undefined : { padding: '4px 0' }}>
          <div className="eyebrow" style={{ fontSize: 11 }}>
            {label}
          </div>
          <div style={{ fontSize: compact ? 22 : 32, fontWeight: 330, fontVariantNumeric: 'tabular-nums' }}>
            {value.toString()}
          </div>
          {!compact && <div className="faint" style={{ fontSize: 12 }}>{help}</div>}
        </div>
      ))}
    </div>
  )
}

export function ProviderCard({ provider, minStake }: { provider: ProviderView; minStake?: bigint }) {
  const { name, source } = providerLabel(provider)
  const unbonding = provider.record.unstakeAvailableAt > 0n && provider.record.unstakeAvailableAt > nowSeconds()
  const canRequest = provider.capabilities.some((c) => provider.eligibleFor(c))
  return (
    <div className="card stack" style={{ gap: 14 }}>
      <div className="spread" style={{ alignItems: 'flex-start' }}>
        <div>
          <h3 title={source}>{name ?? 'Unlabelled provider'}</h3>
          <Addr address={provider.address} label={name ? undefined : null} />
        </div>
        <ProviderStatus record={provider.record} minStake={minStake} />
      </div>
      <dl className="kv">
        <dt>Services</dt>
        <dd className="row" style={{ gap: 6 }}>
          {provider.capabilities.length === 0 ? (
            <span className="faint">None listed</span>
          ) : (
            provider.capabilities.map((c) => (
              <span key={c} className="chip">
                <ServiceName hash={c} short />
              </span>
            ))
          )}
        </dd>
        <dt>Service area</dt>
        <dd>
          <RegionName hash={provider.record.locationHash} />
        </dd>
        <dt>Stake</dt>
        <dd>
          <Usdc amount={provider.record.stake} />
          {unbonding && <span className="faint"> · unbonding</span>}
        </dd>
        <dt>Active jobs</dt>
        <dd>{provider.record.activeJobs}</dd>
      </dl>
      <div style={{ borderTop: '1px solid var(--border-moss)', paddingTop: 14 }}>
        <div className="eyebrow" style={{ marginBottom: 8 }}>
          Clinova performance
        </div>
        <ReputationPanel reputation={provider.reputation} compact />
      </div>
      {canRequest ? (
        <Link className="btn btn-ghost" to={`/buyer/new?provider=${provider.address}`}>
          Request a service
        </Link>
      ) : (
        <span className="faint" style={{ fontSize: 13 }}>
          Not currently accepting requests.
        </span>
      )}
    </div>
  )
}
