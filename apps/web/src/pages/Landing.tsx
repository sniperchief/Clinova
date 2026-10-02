import { Link } from 'react-router-dom'
import { CONTRACT_LIST } from '../config/contracts'
import { Skeleton, TxLink } from '../components/ui'
import { useEvents, useProtocol, useProviders } from '../hooks/useClinova'
import { recentActivity } from '../lib/activity'
import { addressUrl, formatUsdc, shortAddress } from '../lib/format'

const FLOW = [
  ['DISCOVER', 'Find verified diagnostic capacity by service and area.'],
  ['RESERVE', 'Request a service from one provider or the whole network.'],
  ['ESCROW', 'Payment is secured onchain in USDC before work begins.'],
  ['VERIFY', 'Proof of service is reviewed by the buyer or an authorized verifier.'],
  ['SETTLE', 'USDC is released or refunded according to protocol rules.'],
  ['REPUTATION', 'Every outcome becomes part of the provider’s public record.'],
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

/** Full-bleed 3:2 photo at the top of a content card. Illustrative stock photography, not Clinova participants. */
function RoleMedia({ name, alt }: { name: string; alt: string }) {
  return (
    <picture className="media-card-img">
      <source type="image/webp" media="(max-width: 640px)" srcSet={`/media/${name}-720.webp`} />
      <source type="image/webp" srcSet={`/media/${name}-1200.webp`} />
      <img src={`/media/${name}.jpg`} alt={alt} loading="lazy" width={1200} height={800} />
    </picture>
  )
}

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
            <span className="eyebrow">Clinova Testnet · Arbitrum Sepolia</span>
            <h1>
              Healthcare capacity, <span className="mint">connected.</span>
            </h1>
            <p className="lede">
              Clinova lets healthcare businesses discover, reserve, verify and pay for diagnostic capacity across a
              distributed network of independent labs and clinics.
            </p>
            <div className="row" style={{ gap: 16 }}>
              <Link to="/discover" className="btn btn-primary">
                Launch Clinova
              </Link>
              <a href="#how" className="btn btn-ghost">
                How it works
              </a>
            </div>
          </div>
        </div>
        <span className="hero-caption">Illustrative photography</span>
      </section>

      <div className="container live-wrap">
        <LiveNetwork />
      </div>

      <section className="band">
        <div className="container problem-grid">
          <div>
            <span className="eyebrow">The problem</span>
            <h2>
              Diagnostic capacity exists. <span className="mint">Reliable access</span> to it doesn’t.
            </h2>
            <p className="intro">
              Labs and clinics have equipment and staff that sit idle for part of every day. Meanwhile telemedicine
              companies, insurers, hospitals and digital health platforms need tests done wherever their patients are —
              and reaching each provider means a separate contract, manual coordination and slow reconciliation.
            </p>
            <p className="intro">
              Clinova is a shared coordination layer between the two. Providers stake to join and are verified. Buyers
              reserve capacity with payment held in escrow. Settlement follows a reviewed proof of service, and each
              outcome is added to a public performance record that neither side can edit.
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

      <section className="band wash" id="how">
        <div className="container">
          <div className="how-head">
            <div>
              <span className="eyebrow">How it works</span>
              <h2>From request to settlement, with a shared record at every step.</h2>
              <p className="intro">
                Each step below is a transaction on Arbitrum that buyer, provider and verifier can all inspect. The sample,
                the evidence and any results stay with the provider — only payment, status and a salted commitment are
                recorded.
              </p>
            </div>
            <figure className="media-frame">
              <picture>
                <source type="image/webp" media="(max-width: 640px)" srcSet="/media/collection-800.webp" />
                <source type="image/webp" srcSet="/media/collection-1600.webp" />
                <img
                  src="/media/collection.jpg"
                  alt="A gloved hand holding two capped sample tubes"
                  loading="lazy"
                  width={1600}
                  height={1000}
                />
              </picture>
            </figure>
          </div>
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
          <span className="eyebrow">Who it’s for</span>
          <h2>Three roles, one workflow.</h2>
          <div className="grid grid-3" style={{ marginTop: 48 }}>
            <Link to="/buyer" className="card card-link media-card">
              <RoleMedia name="role-buyer" alt="A doctor at a desk ordering tests on a computer" />
              <div className="media-card-body">
                <span className="eyebrow">Healthcare businesses</span>
                <h3>Reserve diagnostics on demand</h3>
                <p className="muted" style={{ margin: 0 }}>
                  Telemedicine, insurers, hospitals and platforms create requests, escrow USDC, confirm completion or open
                  a dispute, and see settlement as it happens.
                </p>
                <span className="link">Open buyer dashboard →</span>
              </div>
            </Link>
            <Link to="/provider" className="card card-link media-card">
              <RoleMedia name="role-provider" alt="Two lab scientists working at a microscope bench" />
              <div className="media-card-body">
                <span className="eyebrow">Providers</span>
                <h3>Turn spare capacity into revenue</h3>
                <p className="muted" style={{ margin: 0 }}>
                  Labs and clinics register, stake, get verified, publish the tests they offer, accept jobs, submit proof
                  of service and withdraw earnings.
                </p>
                <span className="link">Become a provider →</span>
              </div>
            </Link>
            <div className="card media-card">
              <RoleMedia name="role-verifier" alt="A lab technician reviewing results on an analyzer screen" />
              <div className="media-card-body">
                <span className="eyebrow">Verifiers</span>
                <h3>Review evidence, resolve disputes</h3>
                <p className="muted" style={{ margin: 0 }}>
                  A trusted verification role checks providers and proof of service, and resolves disputes. Verifiers can
                  never review a request they are party to — the contracts enforce it.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="band">
        <div className="container">
          <span className="eyebrow">Trust and privacy</span>
          <h2>What Clinova records — and what it deliberately doesn’t.</h2>
          <div className="grid grid-2" style={{ marginTop: 48, gap: 24 }}>
            <div className="card">
              <h3>Onchain, on Arbitrum</h3>
              <ul className="muted" style={{ paddingLeft: 18, margin: '12px 0 0', lineHeight: 1.8 }}>
                <li>Request status, deadlines and the escrowed USDC amount</li>
                <li>Provider stake, verification and the service codes it offers</li>
                <li>A salted cryptographic commitment to the proof of service</li>
                <li>Settlement, refunds and outcome counters for reputation</li>
              </ul>
            </div>
            <div className="card">
              <h3>Never onchain</h3>
              <ul className="muted" style={{ paddingLeft: 18, margin: '12px 0 0', lineHeight: 1.8 }}>
                <li>Patient names, contact details, diagnoses or results</li>
                <li>Medical reports or the evidence itself — only its salted hash</li>
                <li>Provider licences and identity documents</li>
                <li>Free-text dispute reasons — only a salted reference</li>
              </ul>
            </div>
          </div>
          <p className="notice" style={{ marginTop: 24, maxWidth: 820 }}>
            The blockchain does not prove a medical service happened. Clinova records a commitment to the evidence, and
            an authorized verification process — or the paying buyer — decides whether it supports completion. Clinova
            does not provide medical advice or guarantee provider quality or availability.
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

      <section className="band" style={{ borderBottom: 'none', textAlign: 'center' }}>
        <div className="container">
          <h2 style={{ margin: '0 auto' }}>Try the full flow on testnet.</h2>
          <p className="intro" style={{ margin: '20px auto 36px' }}>
            Connect a wallet on Arbitrum Sepolia with test USDC and ETH. Every step is a real transaction you can open on
            Arbiscan.
          </p>
          <div className="row" style={{ justifyContent: 'center', gap: 16 }}>
            <Link to="/discover" className="btn btn-primary">
              Enter testnet
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
