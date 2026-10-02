import { useMemo, useState } from 'react'
import type { Hex } from 'viem'
import { REGIONS, SERVICE_TYPES } from '../config/catalog'
import { ProviderCard } from '../components/Provider'
import { providerLabel } from '../lib/providerLabel'
import { Empty, LoadError, Skeleton } from '../components/ui'
import { useProtocol, useProviders } from '../hooks/useClinova'

export function Discover() {
  const providers = useProviders()
  const minStake = useProtocol().data?.minStake
  const [service, setService] = useState<Hex | ''>('')
  const [region, setRegion] = useState<Hex | ''>('')
  const [onlyAvailable, setOnlyAvailable] = useState(false)
  const [query, setQuery] = useState('')

  const list = useMemo(() => {
    const all = providers.data ?? []
    const q = query.trim().toLowerCase()
    return all
      .filter((p) => !service || p.capabilities.some((c) => c.toLowerCase() === service))
      .filter((p) => !region || p.record.locationHash.toLowerCase() === region)
      .filter((p) =>
        !onlyAvailable ? true : service ? p.eligibleFor(service) : p.capabilities.some((c) => p.eligibleFor(c)),
      )
      .filter((p) => !q || p.address.toLowerCase().includes(q) || (providerLabel(p).name ?? '').toLowerCase().includes(q))
      .sort((a, b) => {
        const ea = a.capabilities.some((c) => a.eligibleFor(c)) ? 1 : 0
        const eb = b.capabilities.some((c) => b.eligibleFor(c)) ? 1 : 0
        if (ea !== eb) return eb - ea
        return Number(b.reputation.successfulJobs - a.reputation.successfulJobs)
      })
  }, [providers.data, service, region, onlyAvailable, query])

  return (
    <div className="container page">
      <div className="page-head">
        <div>
          <span className="eyebrow">Discover</span>
          <h1>Diagnostic capacity on the network</h1>
          <p>
            Every provider below registered and staked USDC onchain. Status, services, stake and performance are read live
            from the Clinova contracts.
          </p>
        </div>
      </div>

      <div className="card" style={{ padding: 20, marginBottom: 24 }}>
        <div className="grid grid-4" style={{ alignItems: 'end' }}>
          <div className="field">
            <label htmlFor="f-service">Diagnostic service</label>
            <select id="f-service" className="input" value={service} onChange={(e) => setService(e.target.value as Hex)}>
              <option value="">All services</option>
              {SERVICE_TYPES.map((s) => (
                <option key={s.hash} value={s.hash}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="f-region">Service area</label>
            <select id="f-region" className="input" value={region} onChange={(e) => setRegion(e.target.value as Hex)}>
              <option value="">All areas</option>
              {REGIONS.map((r) => (
                <option key={r.hash} value={r.hash}>
                  {r.name}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="f-q">Name or address</label>
            <input id="f-q" className="input" placeholder="Search" value={query} onChange={(e) => setQuery(e.target.value)} />
          </div>
          <label className={`check-pill ${onlyAvailable ? 'on' : ''}`} style={{ justifyContent: 'center', height: 48 }}>
            <input type="checkbox" checked={onlyAvailable} onChange={(e) => setOnlyAvailable(e.target.checked)} />
            Accepting requests only
          </label>
        </div>
      </div>

      {providers.error && <LoadError error={providers.error} />}
      {providers.isLoading ? (
        <div className="grid grid-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="card stack">
              <Skeleton width="60%" height={22} />
              <Skeleton />
              <Skeleton />
              <Skeleton width="40%" />
            </div>
          ))}
        </div>
      ) : list.length === 0 ? (
        <Empty>
          {(providers.data?.length ?? 0) === 0
            ? 'No providers have registered yet.'
            : 'No providers match these filters. Providers whose region is a private (salted) commitment only appear under “All areas”.'}
        </Empty>
      ) : (
        <div className="grid grid-3">
          {list.map((p) => (
            <ProviderCard key={p.address} provider={p} minStake={minStake} />
          ))}
        </div>
      )}

      <p className="notice" style={{ marginTop: 32 }}>
        The contracts store only hashes for provider profiles and service areas. Names come from offchain profiles whose
        hash matches the onchain commitment, or are marked “demo” when synthetic. Verification is performed by an
        authorized verifier and is not a guarantee of service quality or availability.
      </p>
    </div>
  )
}
