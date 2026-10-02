import { useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import type { Hex } from 'viem'
import { useConnection } from 'wagmi'
import { REGIONS, SERVICE_TYPES } from '../config/catalog'
import { DashHeader, HowItWorks, JobList, MetricStrip, Panel, SetupTracker, Tabs } from '../components/Dashboard'
import { StepCard, TxButton } from '../components/Tx'
import { RegionName, ServiceName, Skeleton, Usdc } from '../components/ui'
import { NetworkGate } from '../components/Wallet'
import { useAccountState, useNow, useProtocol, useProviders, useRequests } from '../hooks/useClinova'
import { profileHash, type ProviderProfile } from '../lib/commitments'
import { calls } from '../lib/contracts/calls'
import type { AccountState, ProtocolState } from '../lib/contracts/reads'
import { isTerminal, Status } from '../lib/contracts/types'
import { addressUrl, formatDateTime, formatDuration, formatUsdc, isZeroAddress, parseUsdc, sameAddress, shortAddress, usdc } from '../lib/format'
import { jobState } from '../lib/jobs'
import { saveProfile } from '../lib/localRecords'
import { monogram, providerAvailability, providerLabel } from '../lib/providerLabel'

export function Provider() {
  const { address } = useConnection()
  const account = useAccountState()
  const protocol = useProtocol().data

  return (
    <div className="container page">
      {!address ? (
        <Welcome />
      ) : !account.data || !protocol ? (
        <div className="stack">
          <Skeleton height={88} />
          <Skeleton height={96} />
          <Skeleton height={320} />
        </div>
      ) : account.data.provider.registered ? (
        <Dashboard account={account.data} protocol={protocol} />
      ) : (
        <Onboarding account={account.data} protocol={protocol} />
      )}
    </div>
  )
}

const HOW_IT_WORKS: [string, string][] = [
  ['Register and stake', 'List your lab, service area and tests, and stake USDC in one transaction.'],
  ['Get verified', 'A Clinova verifier checks your business and claimed services offchain.'],
  ['Accept jobs', 'Take open requests for the tests you offer, before their deadlines.'],
  ['Get paid', 'Submit proof of service; once it is accepted, USDC is released to you.'],
]

function Welcome() {
  const minStake = useProtocol().data?.minStake
  return (
    <div className="intro-grid">
      <div>
        <span className="eyebrow">Providers</span>
        <h1 className="intro-title">Turn spare diagnostic capacity into revenue.</h1>
        <p className="intro-text">
          Labs and clinics join Clinova by staking {minStake !== undefined ? usdc(minStake) : 'USDC'}, get verified, and
          then receive paid requests from healthcare businesses — settled in USDC when the work is accepted.
        </p>
        <div className="panel connect-panel">
          <h3>Connect your organisation’s wallet</h3>
          <p className="muted">It holds your stake, receives your earnings and signs every job action.</p>
          <NetworkGate>{null}</NetworkGate>
        </div>
      </div>
      <HowItWorks title="How it works for providers" steps={HOW_IT_WORKS} />
    </div>
  )
}

// ------------------------------------------------------------------------------------------------------------------

function Onboarding({ account, protocol }: { account: AccountState; protocol: ProtocolState }) {
  const [name, setName] = useState('')
  const [region, setRegion] = useState(REGIONS[0])
  const [services, setServices] = useState<Hex[]>([SERVICE_TYPES[0].hash])
  const [stake, setStake] = useState(formatUsdc(protocol.minStake).replace(/,/g, ''))

  const stakeUnits = parseUsdc(stake)
  const profile: ProviderProfile = { v: 'CLINOVA_PROFILE_V1', name: name.trim(), region: region.code }
  const errors: string[] = []
  if (!profile.name) errors.push('Enter a business name.')
  if (services.length === 0) errors.push('Choose at least one service.')
  if (stakeUnits === null) errors.push('Enter a valid stake amount.')
  else if (stakeUnits < protocol.minStake) errors.push(`Stake must be at least ${usdc(protocol.minStake)}.`)
  const valid = errors.length === 0 && stakeUnits !== null
  const approved = stakeUnits !== null && account.allowanceRegistry >= stakeUnits
  const enough = stakeUnits !== null && account.usdcBalance >= stakeUnits

  const toggle = (h: Hex) => setServices((s) => (s.includes(h) ? s.filter((x) => x !== h) : [...s, h]))

  return (
    <>
      <div className="page-head">
        <div>
          <span className="eyebrow">Provider onboarding</span>
          <h1>Become a Clinova provider</h1>
          <p>Register your lab or clinic. Verification and activation follow once you are registered.</p>
        </div>
      </div>

      <SetupTracker
        steps={[
          { title: 'Register & stake', done: false },
          { title: 'Get verified', done: false },
          { title: 'Activate', done: false },
          { title: 'Accept jobs', done: false },
        ]}
      />

      <div className="dash-grid">
        <div className="dash-main">
          <Panel title="Business profile" subtitle="Published business information. Only its hash is stored onchain.">
            <div className="form-grid">
              <div className="field">
                <label htmlFor="pname">Business display name</label>
                <input
                  id="pname"
                  className="input"
                  value={name}
                  maxLength={80}
                  placeholder="e.g. Demo Diagnostic Center (synthetic)"
                  onChange={(e) => setName(e.target.value)}
                />
                <span className="help">The profile is kept in this browser for display. For the testnet demo, use a synthetic name.</span>
              </div>
              <div className="field">
                <label htmlFor="pregion">Service area</label>
                <select
                  id="pregion"
                  className="input"
                  value={region.code}
                  onChange={(e) => setRegion(REGIONS.find((r) => r.code === e.target.value)!)}
                >
                  {REGIONS.map((r) => (
                    <option key={r.code} value={r.code}>
                      {r.name}
                    </option>
                  ))}
                </select>
                <span className="help">A coarse city or zone — never a street address.</span>
              </div>
            </div>
          </Panel>

          <Panel title="Services you offer" subtitle="A verifier checks these claims. Adding a service later requires re-verification.">
            <div className="checks">
              {SERVICE_TYPES.map((s) => (
                <label key={s.hash} className={`check-pill ${services.includes(s.hash) ? 'on' : ''}`}>
                  <input type="checkbox" checked={services.includes(s.hash)} onChange={() => toggle(s.hash)} />
                  {s.name}
                </label>
              ))}
            </div>
          </Panel>

          <Panel title="Stake" subtitle={`Minimum ${usdc(protocol.minStake)}, read from the ProviderRegistry contract.`}>
            <div className="form-grid">
              <div className="field">
                <label htmlFor="pstake">Amount to stake</label>
                <div className="input-suffix">
                  <input id="pstake" className="input" inputMode="decimal" value={stake} onChange={(e) => setStake(e.target.value)} />
                  <span>USDC</span>
                </div>
                <span className="help">
                  Wallet balance: <Usdc amount={account.usdcBalance} />
                </span>
              </div>
              <ul className="terms">
                <li>Held by the ProviderRegistry contract while you are a provider.</li>
                <li>
                  To exit, request to unstake; after {formatDuration(protocol.unbondingPeriod)} you can withdraw the full stake
                  once you have no open jobs.
                </li>
                <li>No slashing in this version. Missed deadlines and upheld disputes go on your public record.</li>
              </ul>
            </div>
          </Panel>
        </div>

        <aside className="dash-side sticky-side">
          <Panel title="Review">
            <dl className="kv">
              <dt>Name</dt>
              <dd>{profile.name || <span className="faint">Not set</span>}</dd>
              <dt>Area</dt>
              <dd>{region.name}</dd>
              <dt>Services</dt>
              <dd>{services.length ? `${services.length} selected` : <span className="faint">None</span>}</dd>
              <dt>Stake</dt>
              <dd>{stakeUnits !== null ? <Usdc amount={stakeUnits} /> : '—'}</dd>
            </dl>
          </Panel>

          <NetworkGate>
            <div className="steps">
              {protocol.registryPaused && (
                <div className="banner warn">
                  <div>
                    <strong>New registrations are paused.</strong>
                    <p>Please try again later.</p>
                  </div>
                </div>
              )}
              {stakeUnits !== null && !enough && (
                <div className="banner bad">
                  <div>
                    <strong>Not enough USDC.</strong>
                    <p>
                      This wallet holds <Usdc amount={account.usdcBalance} />. Get test USDC at faucet.circle.com.
                    </p>
                  </div>
                </div>
              )}
              {errors.length > 0 && <p className="faint" style={{ margin: 0, fontSize: 13 }}>{errors.join(' ')}</p>}
              <StepCard
                index={1}
                total={2}
                title="Approve USDC for your stake"
                status={approved ? 'done' : valid ? 'current' : 'todo'}
                description={`Allow the ProviderRegistry to move exactly ${stakeUnits !== null ? usdc(stakeUnits) : 'your stake'}.`}
              >
                <TxButton call={stakeUnits !== null ? calls.approveRegistry(stakeUnits) : null} disabled={!enough || protocol.registryPaused} block>
                  Approve {stakeUnits !== null ? usdc(stakeUnits) : 'USDC'}
                </TxButton>
              </StepCard>
              <StepCard
                index={2}
                total={2}
                title="Register and stake"
                status={approved && valid ? 'current' : 'todo'}
                description="Creates your provider record, lists your services and deposits your stake in one transaction."
              >
                <TxButton
                  call={valid && stakeUnits !== null ? calls.register(profileHash(profile), region.hash, services, stakeUnits) : null}
                  disabled={!enough || protocol.registryPaused}
                  onConfirmed={() => saveProfile(profile)}
                  block
                >
                  Register as provider
                </TxButton>
              </StepCard>
            </div>
          </NetworkGate>
        </aside>
      </div>
    </>
  )
}

// ------------------------------------------------------------------------------------------------------------------

type JobTab = 'available' | 'active' | 'history'

function Dashboard({ account, protocol }: { account: AccountState; protocol: ProtocolState }) {
  const { address } = useConnection()
  const providers = useProviders().data
  const requests = useRequests().data
  const now = useNow()
  const me = providers?.find((p) => sameAddress(p.address, address))
  const rec = account.provider
  const name = me ? providerLabel(me).name : null
  const availability = providerAvailability(rec, protocol.minStake)
  const [tab, setTab] = useState<JobTab | null>(null)

  const all = requests ?? []
  const { available, active, history } = {
      available: all.filter(
        (r) =>
          r.request.status === Status.OPEN &&
          now <= r.request.acceptDeadline &&
          !sameAddress(r.request.buyer, address) &&
          (isZeroAddress(r.request.provider) || sameAddress(r.request.provider, address)) &&
          !!me?.capabilities.some((c) => c.toLowerCase() === r.request.serviceType.toLowerCase()),
      ),
      active: all.filter((r) => sameAddress(r.request.provider, address) && r.request.status !== Status.OPEN && !isTerminal(r.request.status)),
      history: all
        .filter((r) => sameAddress(r.request.provider, address) && isTerminal(r.request.status))
        .sort((a, b) => Number(b.id - a.id)),
  }

  const activeNeedingAction = active.filter((r) => jobState(r, 'provider', now).actionNeeded).length
  const currentTab: JobTab = tab ?? (activeNeedingAction > 0 || available.length === 0 ? 'active' : 'available')
  const lists = { available, active, history }

  return (
    <>
      <DashHeader
        eyebrow="Provider dashboard"
        title={name ?? 'Your provider account'}
        tile={monogram(name) ?? <img src="/brand/favicon-48.png" alt="" width={26} height={26} />}
        meta={
          <>
            <span className={`pill pill-${availability.tone}`}>{availability.label}</span>
            <RegionName hash={rec.locationHash} />
            <a className="mono link" href={addressUrl(address!)} target="_blank" rel="noreferrer">
              {shortAddress(address!)} ↗
            </a>
          </>
        }
        actions={
          <Link to="/discover" className="btn btn-ghost">
            View in directory
          </Link>
        }
      />

      <Setup account={account} protocol={protocol} />

      {account.escrowCredit > 0n && (
        <div className="callout">
          <div>
            <span className="callout-label">Earnings ready</span>
            <strong>
              <Usdc amount={account.escrowCredit} />
            </strong>
            <p>Payments for settled jobs are credited to you in ClinovaEscrow. Withdrawals are never paused.</p>
          </div>
          <TxButton call={calls.withdrawCredit()}>Withdraw earnings</TxButton>
        </div>
      )}

      <MetricStrip
        items={[
          { label: 'Available earnings', value: formatUsdc(account.escrowCredit), unit: 'USDC', highlight: account.escrowCredit > 0n },
          {
            label: 'Stake',
            value: formatUsdc(rec.stake),
            unit: 'USDC',
            hint: rec.unstakeAvailableAt > 0n ? `Unbonding until ${formatDateTime(rec.unstakeAvailableAt)}` : `Minimum ${usdc(protocol.minStake)}`,
          },
          { label: 'Active jobs', value: rec.activeJobs, hint: activeNeedingAction ? `${activeNeedingAction} need your action` : 'Accepted, not yet closed' },
          { label: 'Successful jobs', value: account.reputation.successfulJobs.toString(), hint: 'Settled with payment' },
        ]}
      />

      <div className="dash-grid">
        <div className="dash-main">
          <Panel title="Jobs" subtitle="Open requests for the services you offer, and the jobs you have taken on." flush>
            <Tabs<JobTab>
              value={currentTab}
              onChange={setTab}
              tabs={[
                { id: 'available', label: 'Available', count: available.length, attention: true },
                { id: 'active', label: 'Active', count: active.length, attention: activeNeedingAction > 0 },
                { id: 'history', label: 'History', count: history.length },
              ]}
            />
            {!requests ? (
              <div style={{ padding: 20 }}>
                <Skeleton height={64} />
              </div>
            ) : (
              <JobList
                jobs={lists[currentTab]}
                perspective="provider"
                now={now}
                empty={
                  currentTab === 'available'
                    ? rec.active
                      ? 'No open requests match your services right now. New requests appear here automatically.'
                      : 'Activate your account to see open requests for your services.'
                    : currentTab === 'active'
                      ? 'No active jobs. Accept an available request to get started.'
                      : 'Completed and closed jobs will appear here.'
                }
              />
            )}
          </Panel>
        </div>

        <aside className="dash-side">
          <Panel title="Performance" subtitle="From ReputationRegistry · cannot be edited by anyone">
            <dl className="perf-tiles">
              {(
                [
                  ['Completed', account.reputation.completedJobs, 'Jobs where you submitted proof of service'],
                  ['Successful', account.reputation.successfulJobs, 'Jobs that settled with payment to you'],
                  ['Failed', account.reputation.failedJobs, 'Jobs where you were found at fault or missed the deadline'],
                  ['Disputed', account.reputation.disputes, 'Jobs that were contested — not a fault count'],
                ] as [string, bigint, string][]
              ).map(([label, value, help]) => (
                <div key={label} title={help}>
                  <dd>{value.toString()}</dd>
                  <dt>{label}</dt>
                </div>
              ))}
            </dl>
          </Panel>
          <Capabilities offered={me?.capabilities ?? []} verified={rec.verified} />
          <StakeManagement account={account} protocol={protocol} />
        </aside>
      </div>
    </>
  )
}

function Setup({ account, protocol }: { account: AccountState; protocol: ProtocolState }) {
  const rec = account.provider
  if (rec.active) return null
  const unbonding = rec.unstakeAvailableAt > 0n
  const staked = rec.stake >= protocol.minStake && !unbonding
  let body: ReactNode
  if (unbonding) body = <p>Your stake is unbonding, so you are not receiving requests. Withdraw it from the Stake panel when it is released.</p>
  else if (!staked) body = <p>Your stake is below the {usdc(protocol.minStake)} minimum. Top it up in the Stake panel to continue.</p>
  else if (!rec.verified)
    body = (
      <p>
        <strong>Waiting for verification.</strong> A Clinova verifier reviews your business profile and claimed services
        offchain, then verifies your wallet onchain. Share your wallet address with the verification team — this page
        updates automatically.
      </p>
    )
  else
    body = (
      <div className="setup-action">
        <p>
          <strong>You’re verified.</strong> Activate your account to start receiving requests for your services.
        </p>
        <TxButton call={calls.activate()}>Activate</TxButton>
      </div>
    )
  return (
    <SetupTracker
      steps={[
        { title: 'Registered', done: true },
        { title: 'Staked', done: staked },
        { title: 'Verified', done: rec.verified },
        { title: 'Active', done: rec.active },
      ]}
    >
      {body}
    </SetupTracker>
  )
}

function Capabilities({ offered, verified }: { offered: Hex[]; verified: boolean }) {
  const [adding, setAdding] = useState<Hex | ''>('')
  const notOffered = SERVICE_TYPES.filter((s) => !offered.some((o) => o.toLowerCase() === s.hash))
  return (
    <Panel title="Services" subtitle="What buyers can request from you.">
      {offered.length === 0 ? (
        <p className="faint" style={{ margin: 0 }}>
          None listed.
        </p>
      ) : (
        <ul className="service-rows">
          {offered.map((h) => (
            <li key={h}>
              <ServiceName hash={h} />
              <TxButton call={calls.removeCapability(h)} variant="small" confirm="Stop offering this service? Your verification is kept.">
                Remove
              </TxButton>
            </li>
          ))}
        </ul>
      )}
      {notOffered.length > 0 && (
        <div className="panel-section">
          <div className="field">
            <label htmlFor="addcap">Add a service</label>
            <select id="addcap" className="input" value={adding} onChange={(e) => setAdding(e.target.value as Hex)}>
              <option value="">Choose…</option>
              {notOffered.map((s) => (
                <option key={s.hash} value={s.hash}>
                  {s.name}
                </option>
              ))}
            </select>
            {verified && <span className="help warn-text">Adding a service removes your verification until a verifier re-verifies you.</span>}
          </div>
          <TxButton
            call={adding ? calls.addCapability(adding) : null}
            variant="ghost"
            confirm={verified ? 'Adding a service will remove your verification until re-verified. Continue?' : undefined}
            onConfirmed={() => setAdding('')}
            block
          >
            Add service
          </TxButton>
        </div>
      )}
    </Panel>
  )
}

function StakeManagement({ account, protocol }: { account: AccountState; protocol: ProtocolState }) {
  const rec = account.provider
  const now = useNow()
  const [amount, setAmount] = useState('')
  const units = parseUsdc(amount)
  const unbonding = rec.unstakeAvailableAt > 0n
  const ready = unbonding && now >= rec.unstakeAvailableAt
  const approved = units !== null && units > 0n && account.allowanceRegistry >= units
  const stakeOk = rec.stake >= protocol.minStake

  return (
    <Panel title="Stake & availability" subtitle={`Unbonding period: ${formatDuration(protocol.unbondingPeriod)}`}>
      <dl className="kv">
        <dt>Current stake</dt>
        <dd>
          <Usdc amount={rec.stake} />
        </dd>
        <dt>Wallet balance</dt>
        <dd>
          <Usdc amount={account.usdcBalance} />
        </dd>
        {unbonding && (
          <>
            <dt>Withdrawable</dt>
            <dd>{ready ? 'Now' : formatDateTime(rec.unstakeAvailableAt)}</dd>
          </>
        )}
      </dl>

      {unbonding ? (
        <div className="panel-section">
          <p className="muted" style={{ margin: 0, fontSize: 14 }}>
            {rec.activeJobs > 0
              ? `You still have ${rec.activeJobs} open job(s). Stake can be withdrawn once they close.`
              : ready
                ? 'Your unbonding period is over. Withdraw the full stake to your wallet.'
                : 'Your stake is unbonding. You are not receiving new jobs.'}
          </p>
          <TxButton call={calls.withdrawStake()} disabled={!ready || rec.activeJobs > 0} block>
            Withdraw stake
          </TxButton>
        </div>
      ) : (
        <>
          <div className="panel-section">
            <div className="field">
              <label htmlFor="topup">Add stake</label>
              <div className="input-suffix">
                <input id="topup" className="input" inputMode="decimal" value={amount} placeholder="0" onChange={(e) => setAmount(e.target.value)} />
                <span>USDC</span>
              </div>
              {!stakeOk && <span className="help">At least {usdc(protocol.minStake - rec.stake)} more is needed to be eligible.</span>}
            </div>
            {!approved ? (
              <TxButton call={units && units > 0n ? calls.approveRegistry(units) : null} variant="ghost" disabled={protocol.registryPaused} block>
                Step 1 of 2 · Approve {units && units > 0n ? usdc(units) : 'USDC'}
              </TxButton>
            ) : (
              <TxButton call={calls.depositStake(units!)} variant="ghost" disabled={protocol.registryPaused} onConfirmed={() => setAmount('')} block>
                Step 2 of 2 · Deposit {usdc(units!)}
              </TxButton>
            )}
          </div>
          <div className="panel-section">
            {rec.active && (
              <TxButton call={calls.deactivate()} variant="ghost" block>
                Pause new requests
              </TxButton>
            )}
            {rec.stake > 0n && (
              <TxButton
                call={calls.requestUnstake()}
                variant="danger"
                block
                confirm={`Start unbonding? You will stop receiving requests immediately and can withdraw after ${formatDuration(protocol.unbondingPeriod)}.`}
              >
                Request unstake
              </TxButton>
            )}
          </div>
        </>
      )}
    </Panel>
  )
}
