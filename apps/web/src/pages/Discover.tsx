import { useMemo, useState } from 'react'
import type { Hex } from 'viem'
import { REGIONS, SERVICE_TYPES } from '../config/catalog'
import { ProviderCard } from '../components/Provider'
import { LoadError, Skeleton } from '../components/ui'
import { useProtocol, useProviders } from '../hooks/useClinova'
import type { ProviderView } from '../lib/contracts/reads'
import { providerLabel } from '../lib/providerLabel'

type Sort = 'recommended' | 'completed' | 'stake' | 'newest'

const SORTS: { value: Sort; label: string }[] = [
  { value: 'recommended', label: 'Recommended' },
  { value: 'completed', label: 'Most completed jobs' },
  { value: 'stake', label: 'Highest stake' },
  { value: 'newest', label: 'Newest' },
]

const isAccepting = (p: ProviderView) => p.capabilities.some((c) => p.eligibleFor(c))
const offers = (p: ProviderView, service: Hex) => p.capabilities.some((c) => c.toLowerCase() === service)
const cmp = (a: bigint, b: bigint) => (a === b ? 0 : a > b ? -1 : 1) // descending

export function Discover() {
  const providers = useProviders()
  const minStake = useProtocol().data?.minStake
  const [service, setService] = useState<Hex | ''>('')
  const [region, setRegion] = useState<Hex | ''>('')
  const [onlyAccepting, setOnlyAccepting] = useState(false)
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<Sort>('recommended')

  const all = useMemo(() => providers.data ?? [], [providers.data])

  const summary = useMemo(() => {
    const accepting = all.filter(isAccepting)
    const services = new Set(accepting.flatMap((p) => p.capabilities.filter((c) => p.eligibleFor(c)).map((c) => c.toLowerCase())))
    const completed = all.reduce((sum, p) => sum + p.reputation.completedJobs, 0n)
    return { total: all.length, accepting: accepting.length, services: services.size, completed }
  }, [all])

  const serviceCounts = useMemo(
    () => SERVICE_TYPES.map((s) => ({ ...s, count: all.filter((p) => offers(p, s.hash) && (!onlyAccepting || p.eligibleFor(s.hash))).length })),
    [all, onlyAccepting],
  )

  const list = useMemo(() => {
    const q = query.trim().toLowerCase()
    const filtered = all
      .filter((p) => !service || offers(p, service))
      .filter((p) => !region || p.record.locationHash.toLowerCase() === region)
      .filter((p) => !onlyAccepting || (service ? p.eligibleFor(service) : isAccepting(p)))
      .filter((p) => !q || p.address.toLowerCase().includes(q) || (providerLabel(p).name ?? '').toLowerCase().includes(q))
    return filtered.sort((a, b) => {
      switch (sort) {
        case 'completed':
          return cmp(a.reputation.completedJobs, b.reputation.completedJobs)
        case 'stake':
          return cmp(a.record.stake, b.record.stake)
        case 'newest':
          return cmp(a.registeredAt?.blockNumber ?? 0n, b.registeredAt?.blockNumber ?? 0n)
        default: {
          const byAccepting = Number(isAccepting(b)) - Number(isAccepting(a))
          return byAccepting || cmp(a.reputation.successfulJobs, b.reputation.successfulJobs)
        }
      }
    })
  }, [all, service, region, onlyAccepting, query, sort])

  const filtersActive = !!(service || region || onlyAccepting || query.trim())
  const clear = () => {
    setService('')
    setRegion('')
    setOnlyAccepting(false)
    setQuery('')
  }
  const loading = providers.isLoading

  return (
    <div className="container page discover">
      <header className="disc-head">
        <span className="eyebrow">Discover</span>
        <h1>Diagnostic capacity on the network</h1>
        <p>
          Every provider here has registered and staked USDC on Clinova. Availability, services, stake and performance are
          read live from the protocol contracts on Arbitrum.
        </p>
      </header>

      <section className="disc-summary" aria-label="Network summary">
        {[
          ['Registered providers', summary.total.toString()],
          ['Accepting requests', summary.accepting.toString()],
          ['Services available', summary.services.toString()],
          ['Jobs completed', summary.completed.toString()],
        ].map(([label, value]) => (
          <div key={label}>
            <span className="disc-summary-value">{loading ? <Skeleton width={36} height={28} /> : value}</span>
            <span className="disc-summary-label">{label}</span>
          </div>
        ))}
      </section>

      <div className="disc-toolbar" role="search">
        <label className="disc-search">
          <svg viewBox="0 0 20 20" width="16" height="16" aria-hidden fill="none" stroke="currentColor" strokeWidth="1.6">
            <circle cx="9" cy="9" r="6" />
            <path d="m14 14 4 4" strokeLinecap="round" />
          </svg>
          <input
            className="input"
            type="search"
            placeholder="Search by name or address"
            aria-label="Search providers by name or address"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
        <select className="input" aria-label="Service area" value={region} onChange={(e) => setRegion(e.target.value as Hex)}>
          <option value="">All service areas</option>
          {REGIONS.map((r) => (
            <option key={r.hash} value={r.hash}>
              {r.name}
            </option>
          ))}
        </select>
        <select className="input" aria-label="Sort providers" value={sort} onChange={(e) => setSort(e.target.value as Sort)}>
          {SORTS.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </select>
        <div className="segmented" role="group" aria-label="Availability">
          <button type="button" aria-pressed={!onlyAccepting} onClick={() => setOnlyAccepting(false)}>
            All
          </button>
          <button type="button" aria-pressed={onlyAccepting} onClick={() => setOnlyAccepting(true)}>
            Accepting now
          </button>
        </div>
      </div>

      <div className="disc-chips" role="group" aria-label="Filter by service">
        <button type="button" className="fchip" aria-pressed={!service} onClick={() => setService('')}>
          All services
        </button>
        {serviceCounts.map((s) => (
          <button
            key={s.hash}
            type="button"
            className="fchip"
            aria-pressed={service === s.hash}
            onClick={() => setService(service === s.hash ? '' : s.hash)}
            title={`${s.name} (${s.code})`}
          >
            {s.short}
            <span className="fchip-count">{loading ? '–' : s.count}</span>
          </button>
        ))}
      </div>

      <div className="disc-meta">
        <span>
          {loading ? 'Reading the registry…' : `Showing ${list.length} of ${all.length} provider${all.length === 1 ? '' : 's'}`}
        </span>
        {filtersActive && (
          <button type="button" className="link-button" onClick={clear}>
            Clear filters
          </button>
        )}
      </div>

      {providers.error && <LoadError error={providers.error} />}

      {loading ? (
        <div className="disc-grid">
          {[0, 1, 2].map((i) => (
            <div key={i} className="pcard">
              <div className="pcard-head">
                <Skeleton width={44} height={44} />
                <div className="pcard-id stack" style={{ gap: 8 }}>
                  <Skeleton width="70%" height={18} />
                  <Skeleton width="40%" height={14} />
                </div>
              </div>
              <Skeleton height={26} />
              <Skeleton height={52} />
              <Skeleton height={64} />
            </div>
          ))}
        </div>
      ) : list.length === 0 ? (
        <div className="disc-empty">
          <h3>{all.length === 0 ? 'No providers yet' : 'No providers match these filters'}</h3>
          <p>
            {all.length === 0
              ? 'Providers appear here as soon as they register and stake on Clinova.'
              : 'Try another service or area. Providers whose service area is a private (salted) commitment only appear under “All service areas”.'}
          </p>
          {filtersActive && (
            <button type="button" className="btn btn-ghost" onClick={clear}>
              Clear filters
            </button>
          )}
        </div>
      ) : (
        <div className="disc-grid">
          {list.map((p) => (
            <ProviderCard key={p.address} provider={p} minStake={minStake} />
          ))}
        </div>
      )}

      <aside className="disc-note">
        <strong>About this directory.</strong> The contracts store only hashes for provider profiles and service areas.
        Names come from offchain profiles whose hash matches the onchain commitment, or are marked “demo” when synthetic.
        Verification is performed by an authorized verifier and is not a guarantee of service quality or availability.
      </aside>
    </div>
  )
}
