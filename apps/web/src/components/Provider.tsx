import { Link } from 'react-router-dom'
import { getAddress } from 'viem'
import { DEMO_DIRECTORY } from '../config/catalog'
import type { ProviderView } from '../lib/contracts/reads'
import { loadProfile } from '../lib/localRecords'
import { monogram, providerAvailability, providerLabel } from '../lib/providerLabel'
import { addressUrl, shortAddress } from '../lib/format'
import { RegionName, ServiceName, Usdc } from './ui'

const providerHasProfile = (p: ProviderView) => loadProfile(p.record.metadataHash) !== null

/** Discover-page provider card. Everything shown is read from the registry and reputation contracts,
 *  except the display name (offchain profile verified against its onchain hash, or a marked demo label). */
export function ProviderCard({ provider, minStake }: { provider: ProviderView; minStake?: bigint }) {
  const { name, source } = providerLabel(provider)
  const demo = DEMO_DIRECTORY[getAddress(provider.address)]
  const availability = providerAvailability(provider.record, minStake)
  const canRequest = provider.capabilities.some((c) => provider.eligibleFor(c))
  const initials = monogram(name)
  const rep = provider.reputation
  const perf: [string, bigint, string][] = [
    ['Completed', rep.completedJobs, 'Jobs where the provider submitted proof of service'],
    ['Successful', rep.successfulJobs, 'Jobs that settled with payment to the provider'],
    ['Failed', rep.failedJobs, 'Jobs where the provider was found at fault or missed its deadline'],
    ['Disputed', rep.disputes, 'Jobs that were contested — not a fault count'],
  ]
  return (
    <article className={`pcard ${canRequest ? '' : 'pcard-idle'}`}>
      <header className="pcard-head">
        <div className="pcard-avatar" aria-hidden>
          {initials ?? <img src="/brand/favicon-48.png" alt="" width={22} height={22} />}
        </div>
        <div className="pcard-id">
          <h3 title={source}>
            {name ?? 'Unlabelled provider'}
            {demo && !providerHasProfile(provider) && (
              <span className="chip demo" title={demo.note}>
                demo
              </span>
            )}
          </h3>
          <a className="pcard-addr mono" href={addressUrl(provider.address)} target="_blank" rel="noreferrer" title={provider.address}>
            {shortAddress(provider.address)} ↗
          </a>
        </div>
        <span className={`pill pill-${availability.tone}`}>{availability.label}</span>
      </header>

      <div className="pcard-services">
        {provider.capabilities.length === 0 ? (
          <span className="faint">No services listed</span>
        ) : (
          provider.capabilities.map((c) => (
            <span key={c} className="chip">
              <ServiceName hash={c} short />
            </span>
          ))
        )}
      </div>

      <dl className="pcard-facts">
        <div>
          <dt>Service area</dt>
          <dd>
            <RegionName hash={provider.record.locationHash} />
          </dd>
        </div>
        <div>
          <dt>Stake</dt>
          <dd>
            <Usdc amount={provider.record.stake} />
          </dd>
        </div>
        <div>
          <dt>Active jobs</dt>
          <dd>{provider.record.activeJobs}</dd>
        </div>
      </dl>

      <div className="pcard-perf">
        <div className="pcard-label">Performance on Clinova</div>
        <dl>
          {perf.map(([label, value, help]) => (
            <div key={label} title={help}>
              <dd>{value.toString()}</dd>
              <dt>{label}</dt>
            </div>
          ))}
        </dl>
      </div>

      <footer className="pcard-foot">
        {canRequest ? (
          <Link className="btn btn-primary btn-block" to={`/buyer/new?provider=${provider.address}`}>
            Request a service
          </Link>
        ) : (
          <span className="pcard-unavailable">Not accepting new requests</span>
        )}
      </footer>
    </article>
  )
}
