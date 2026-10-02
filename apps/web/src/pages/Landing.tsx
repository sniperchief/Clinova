import { Link } from 'react-router-dom'
import { CONTRACT_LIST } from '../config/contracts'
import { Skeleton, TxLink } from '../components/ui'
import { useEvents, useProtocol, useProviders } from '../hooks/useClinova'
import { recentActivity } from '../lib/activity'
import { addressUrl, formatUsdc, shortAddress } from '../lib/format'

const FLOW = [
  ['DISCOVER', 'Find verified healthcare providers with the required capability.'],
  ['RESERVE', 'Request and secure available diagnostic capacity.'],
  ['ESCROW', 'Lock payment through Clinova’s smart contracts.'],
  ['VERIFY', 'Confirm completion using proof of service.'],
  ['SETTLE', 'Release payment according to the protocol rules.'],
  ['REPUTATION', 'Record provider performance onchain.'],
]

/** The layered model: applications on top, real-world capacity underneath, protocol guarantees at the base. */
const STACK = [
  ['Telemedicine & healthcare applications', 'Digital consultations and care platforms'],
  ['Clinova infrastructure', 'Onchain coordination layer on Arbitrum'],
  ['Verified real-world healthcare capacity', 'Staked, verified laboratories and clinics'],
  ['Diagnostics & laboratory services', 'Physical tests performed by providers'],
  ['Verification · Escrow · Settlement · Reputation', 'Enforced by the protocol contracts'],
]

const ONCHAIN = [
  'Provider registration and verification status',
  'Service requests',
  'Escrow',
  'Proof-of-service commitments',
  'Settlement',
  'Provider reputation',
]

const OFFCHAIN = [
  'Patient names',
  'Patient medical records',
  'Diagnostic results',
  'Private provider documents',
  'Sensitive healthcare information',
]

const JOURNEY = [
  'Patient needs a test',
  'Telemedicine platform requests capacity',
  'Clinova discovers verified providers',
  'Provider accepts',
  'Payment enters escrow',
  'Service is completed',
  'Proof is verified',
  'Provider is paid',
]

const WHY_ONCHAIN = [
  ['Verifiable provider commitments', 'Independent providers can commit to service requests through a shared protocol.'],
  ['Programmable escrow', 'Payment can be locked until predefined service conditions are met.'],
  [
    'Proof of service',
    'Completion can be represented through verifiable onchain commitments without putting sensitive medical information onchain.',
  ],
  ['Transparent settlement', 'The protocol records how funds move between participants.'],
  [
    'Portable reputation',
    'Provider performance can accumulate at the protocol level rather than remaining trapped inside one marketplace.',
  ],
]

const DEPIN = [
  ['Physical providers', 'contribute capacity', 'Labs and clinics stake, get verified and publish the services they perform.'],
  ['Clinova network', 'coordinates capacity', 'Discovery, commitments, verification, settlement and reputation.'],
  ['Healthcare applications', 'consume capacity', 'Telemedicine and digital health platforms reserve and pay for services.'],
]

const AUDIENCES = [
  ['Telemedicine Platforms', 'Extend digital consultations into real-world diagnostics.', '/buyer', 'Reserve diagnostics →'],
  [
    'Healthcare Applications',
    'Access distributed diagnostic capacity without building physical infrastructure.',
    '/discover',
    'Explore capacity →',
  ],
  [
    'Hospitals & Clinic Networks',
    'Make available capacity accessible to external healthcare applications.',
    '/provider',
    'Contribute capacity →',
  ],
  ['Diagnostic Providers', 'Monetize unused capacity and build portable onchain reputation.', '/provider', 'Become a provider →'],
]

function LiveNetwork() {
  const protocol = useProtocol()
  const providers = useProviders()
  const events = useEvents()
  const p = protocol.data
  const verified = providers.data?.filter((x) => x.record.verified).length
  const stat = (label: string, value: string | undefined, unit?: string) => (
    <div className="stat">
      <div className="label">{label}</div>
      <div className="value" style={{ fontSize: 28 }}>
        {value ?? <Skeleton width={60} height={28} />}
        {unit && value && <small>{unit}</small>}
      </div>
    </div>
  )
  return (
    <div className="live-panel live-strip">
      <div>
        <div className="spread" style={{ marginBottom: 20 }}>
          <span className="eyebrow">
            <span className="live-dot" aria-hidden /> Live network
          </span>
          <span className="faint" style={{ fontSize: 12 }}>
            {p ? `Arbitrum Sepolia · block ${p.blockNumber.toLocaleString()}` : 'Reading Arbitrum Sepolia…'}
          </span>
        </div>
        <div className="grid grid-4">
        {stat('Verified providers', verified?.toString())}
        {stat('Service requests', p ? (p.nextRequestId - 1n).toString() : undefined)}
        {stat('In escrow now', p ? formatUsdc(p.totalLocked) : undefined, 'USDC')}
        {stat('Provider stake', p ? formatUsdc(p.totalStaked) : undefined, 'USDC')}
        </div>
      </div>
      <div className="live-feed">
        <div className="eyebrow" style={{ marginBottom: 4 }}>
          Latest onchain activity
        </div>
        <ul className="feed">
          {events.data ? (
            recentActivity(events.data, 4).map(({ event, text }) => (
              <li key={`${event.transactionHash}-${event.logIndex}`}>
                <span className="muted">{text}</span>
                <TxLink hash={event.transactionHash}>tx</TxLink>
              </li>
            ))
          ) : (
            <li>
              <Skeleton />
            </li>
          )}
        </ul>
      </div>
    </div>
  )
}

const DataList = ({ items }: { items: string[] }) => (
  <ul className="muted" style={{ paddingLeft: 18, margin: '12px 0 0', lineHeight: 1.8 }}>
    {items.map((i) => (
      <li key={i}>{i}</li>
    ))}
  </ul>
)

export function Landing() {
  return (
    <>
      <section className="hero hero-photo">
        <picture className="hero-media" aria-hidden>
          <source type="image/webp" media="(max-width: 900px)" srcSet="/media/hero-1200.webp" />
          <source type="image/webp" srcSet="/media/hero-2400.webp" />
          <img src="/media/hero.jpg" alt="" fetchPriority="high" />
        </picture>
        <div className="hero-shade" aria-hidden />
        <div className="container hero-content">
          <div className="hero-copy">
            <span className="eyebrow">DePIN · RWA infrastructure for telemedicine</span>
            <h1 className="hero-title">
              The <span className="mint">Real-World Healthcare Infrastructure Layer</span> for Telemedicine
            </h1>
            <p className="lede">
              Clinova connects telemedicine platforms and healthcare applications to verified diagnostic capacity across a
              distributed network of physical healthcare providers.
            </p>
            <div className="row" style={{ gap: 16 }}>
              <Link to="/discover" className="btn btn-primary">
                Discover
              </Link>
            </div>
          </div>
        </div>
        <span className="hero-caption">Illustrative photography</span>
      </section>

      <div className="container live-wrap">
        <LiveNetwork />
      </div>

      <section className="band">
        <div className="container">
          <div className="problem-grid">
            <div>
              <span className="eyebrow">The thesis</span>
              <h2>
                Bringing <span className="mint">Real-World Healthcare Capacity</span> Onchain
              </h2>
              <p className="intro">
                Healthcare infrastructure already exists in thousands of laboratories and clinics, but much of that capacity
                is fragmented and difficult for digital healthcare platforms to access programmatically.
              </p>
              <p className="intro">
                Clinova connects this physical infrastructure to an onchain coordination layer, allowing healthcare
                applications to discover providers, reserve capacity, escrow payment, verify service, and settle
                transactions.
              </p>
            </div>
            <ol className="layer-stack" aria-label="How Clinova sits between applications and real-world capacity">
              {STACK.map(([title, text], i) => (
                <li key={title} className={i === 1 ? 'is-core' : undefined}>
                  <strong>{title}</strong>
                  <span>{text}</span>
                </li>
              ))}
            </ol>
          </div>
          <div className="grid grid-2" style={{ marginTop: 56, gap: 24 }}>
            <div className="card">
              <span className="eyebrow">What goes onchain</span>
              <DataList items={ONCHAIN} />
            </div>
            <div className="card">
              <span className="eyebrow">What stays offchain</span>
              <DataList items={OFFCHAIN} />
            </div>
          </div>
          <p className="notice" style={{ marginTop: 24, maxWidth: 820 }}>
            Evidence stays with the provider; only a salted cryptographic commitment to it is recorded. Clinova never puts
            patient information onchain.
          </p>
        </div>
      </section>

      <section className="band wash" id="how">
        <div className="container">
          <div className="how-head">
            <div>
              <span className="eyebrow">The telemedicine use case</span>
              <h2>Built for the Next Generation of Telemedicine</h2>
              <p className="intro">
                A telemedicine platform can connect a patient with a doctor in minutes. But when that patient needs a blood
                test, imaging, or another physical diagnostic service, the digital experience often stops.
              </p>
              <p className="intro">
                Clinova provides the infrastructure layer that connects the digital healthcare experience to real-world
                diagnostic capacity.
              </p>
            </div>
            <figure className="media-frame">
              <picture>
                <source type="image/webp" media="(max-width: 640px)" srcSet="/media/role-buyer-720.webp" />
                <source type="image/webp" srcSet="/media/role-buyer-1200.webp" />
                <img
                  src="/media/role-buyer.jpg"
                  alt="A doctor at a desk ordering tests on a computer"
                  loading="lazy"
                  width={1200}
                  height={800}
                />
              </picture>
            </figure>
          </div>
          <ol className="journey">
            {JOURNEY.map((step, i) => (
              <li key={step}>
                <span className="n">0{i + 1}</span>
                {step}
              </li>
            ))}
          </ol>
        </div>
      </section>

      <section className="band">
        <div className="container">
          <span className="eyebrow">How it works</span>
          <h2>Discover → Reserve → Escrow → Verify → Settle → Reputation</h2>
          <p className="intro">
            Each step is a transaction on Arbitrum that the healthcare business, the provider and the verifier can all
            inspect.
          </p>
          <div className="flow">
            {FLOW.map(([title, text], i) => (
              <div key={title}>
                <span className="n">0{i + 1}</span>
                <h4>{title}</h4>
                <p>{text}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="band">
        <div className="container">
          <span className="eyebrow">DePIN</span>
          <h2>A DePIN Network for Healthcare Capacity</h2>
          <p className="intro">
            Clinova applies the DePIN model to healthcare by connecting physical healthcare providers to a shared digital
            coordination layer.
          </p>
          <p className="intro">
            Providers contribute real-world service capacity. Healthcare applications consume that capacity. Clinova
            coordinates discovery, commitments, verification, settlement, and reputation.
          </p>
          <ol className="depin">
            {DEPIN.map(([title, verb, text], i) => (
              <li key={title} className={i === 1 ? 'is-core' : undefined}>
                <strong>{title}</strong>
                <span className="mint">→ {verb}</span>
                <p>{text}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      <section className="band">
        <div className="container problem-grid">
          <div>
            <span className="eyebrow">RWA</span>
            <h2>Real-World Assets, Reimagined as Healthcare Capacity</h2>
            <p className="intro">
              Clinova does not put patient data onchain or attempt to tokenize medical records.
            </p>
            <p className="intro">
              Instead, it connects blockchain infrastructure to the real-world physical capacity of healthcare providers —
              laboratories, diagnostic equipment, testing availability, and service capacity.
            </p>
            <p className="rwa-line">
              Real-world healthcare capacity <span className="mint">→</span> programmable digital infrastructure
            </p>
            <p className="notice" style={{ marginTop: 24 }}>
              Clinova does not tokenize ownership of laboratories, equipment or other physical assets, and issues no token.
              Payments are in USDC.
            </p>
          </div>
          <figure className="media-asym">
            <picture>
              <source type="image/webp" media="(max-width: 640px)" srcSet="/media/capacity-720.webp" />
              <source type="image/webp" srcSet="/media/capacity-1200.webp" />
              <img src="/media/capacity.jpg" alt="A gloved lab technician holding a capped sample tube" loading="lazy" width={1200} height={1500} />
            </picture>
            <figcaption>Illustrative photography</figcaption>
          </figure>
        </div>
      </section>

      <section className="band wash">
        <div className="container">
          <span className="eyebrow">Why blockchain</span>
          <h2>Why Onchain?</h2>
          <p className="intro">
            Escrow, proof of service, settlement and portable reputation need a shared coordination layer between
            independent healthcare businesses that no single party controls.
          </p>
          <div className="grid grid-3 why-grid">
            {WHY_ONCHAIN.map(([title, text]) => (
              <div key={title} className="card">
                <h3>{title}</h3>
                <p className="muted" style={{ margin: '8px 0 0' }}>
                  {text}
                </p>
              </div>
            ))}
          </div>
          <p className="notice" style={{ marginTop: 24, maxWidth: 820 }}>
            The blockchain does not prove a medical service happened. Clinova records a commitment to the evidence, and
            an authorized verification process — or the paying healthcare business — decides whether it supports
            completion. Clinova does not provide medical advice or guarantee provider quality or availability.
          </p>
          <div className="section">
            <div className="eyebrow" style={{ marginBottom: 12 }}>
              Deployed contracts · verified source on Arbiscan
            </div>
            <div className="grid grid-3">
              {CONTRACT_LIST.map((c) => (
                <a
                  key={c.address}
                  className="card card-link"
                  style={{ padding: 18 }}
                  href={`${addressUrl(c.address)}#code`}
                  target="_blank"
                  rel="noreferrer"
                >
                  <div className="spread">
                    <span>{c.name}</span>
                    <span className="faint">↗</span>
                  </div>
                  <div className="faint" style={{ fontSize: 13 }}>
                    {c.role} · <span className="mono">{shortAddress(c.address)}</span>
                  </div>
                </a>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="band">
        <div className="container">
          <span className="eyebrow">Who it’s for</span>
          <h2>Built for Healthcare Businesses</h2>
          <p className="intro">
            Clinova is B2B infrastructure. Healthcare businesses consume capacity, providers contribute it, and an
            authorized verifier role reviews proof of service and resolves disputes.
          </p>
          <div className="grid grid-4" style={{ marginTop: 48 }}>
            {AUDIENCES.map(([title, text, to, cta]) => (
              <Link key={title} to={to} className="card card-link audience-card">
                <h3>{title}</h3>
                <p className="muted">{text}</p>
                <span className="link">{cta}</span>
              </Link>
            ))}
          </div>
        </div>
      </section>

      <section className="band" style={{ borderBottom: 'none', textAlign: 'center' }}>
        <div className="container">
          <h2 style={{ margin: '0 auto' }}>Try the full flow on testnet.</h2>
          <p className="intro" style={{ margin: '20px auto 36px' }}>
            Connect a wallet on Arbitrum Sepolia with test USDC and ETH. Every step is a real transaction you can open on
            Arbiscan.
          </p>
          <div className="row" style={{ justifyContent: 'center', gap: 16 }}>
            <Link to="/discover" className="btn btn-primary">
              Discover
            </Link>
            <Link to="/provider" className="btn btn-ghost">
              Become a provider
            </Link>
          </div>
        </div>
      </section>
    </>
  )
}
