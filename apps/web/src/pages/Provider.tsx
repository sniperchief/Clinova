import { useMemo, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import type { Hex } from 'viem'
import { useConnection } from 'wagmi'
import { REGIONS, SERVICE_TYPES } from '../config/catalog'
import { ProviderStatus, ReputationPanel } from '../components/Provider'
import { providerLabel } from '../lib/providerLabel'
import { RequestTable } from '../components/Request'
import { StepCard, TxButton } from '../components/Tx'
import { Empty, RegionName, ServiceName, Skeleton, Stat, Usdc } from '../components/ui'
import { NetworkGate } from '../components/Wallet'
import { useAccountState, useNow, useProtocol, useProviders, useRequests } from '../hooks/useClinova'
import { profileHash, type ProviderProfile } from '../lib/commitments'
import { calls } from '../lib/contracts/calls'
import type { AccountState, ProtocolState } from '../lib/contracts/reads'
import { isTerminal, Status } from '../lib/contracts/types'
import { saveProfile } from '../lib/localRecords'
import { formatDateTime, formatDuration, formatUsdc, isZeroAddress, parseUsdc, sameAddress, usdc } from '../lib/format'

export function Provider() {
  const { address } = useConnection()
  const account = useAccountState()
  const protocol = useProtocol().data

  return (
    <div className="container page">
      {!address ? (
        <>
          <Intro />
          <div className="card stack" style={{ maxWidth: 560, marginTop: 24 }}>
            <h3>Connect the wallet your organisation will use</h3>
            <p className="muted" style={{ margin: 0 }}>
              It holds your stake, receives your earnings and signs every job action.
            </p>
            <NetworkGate>{null}</NetworkGate>
          </div>
        </>
      ) : !account.data || !protocol ? (
        <Skeleton height={320} />
      ) : account.data.provider.registered ? (
        <Dashboard account={account.data} protocol={protocol} />
      ) : (
        <>
          <Intro />
          <Onboarding account={account.data} protocol={protocol} />
        </>
      )}
    </div>
  )
}

function Intro() {
  const minStake = useProtocol().data?.minStake
  return (
    <div className="page-head">
      <div>
        <span className="eyebrow">Providers</span>
        <h1>Become a Clinova provider</h1>
        <p>
          Offer your lab or clinic’s diagnostic capacity to healthcare businesses. Register and stake{' '}
          {minStake !== undefined ? usdc(minStake) : 'the minimum stake'}, get verified, then accept jobs and get paid in
          USDC for verified work.
        </p>
      </div>
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
    <div className="split">
      <div className="stack">
        <div className="card">
          <div className="grid grid-4" style={{ gap: 12 }}>
            {[
              ['1', 'Register & stake', 'One transaction'],
              ['2', 'Get verified', 'By a Clinova verifier'],
              ['3', 'Activate', 'Start accepting jobs'],
              ['4', 'Serve & earn', 'Proof → settlement'],
            ].map(([n, t, d]) => (
              <div key={n}>
                <span className="mono faint">0{n}</span>
                <div style={{ marginTop: 4 }}>{t}</div>
                <div className="faint" style={{ fontSize: 13 }}>
                  {d}
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="card stack" style={{ gap: 22 }}>
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
            <span className="help">
              Published business information. Only its hash is stored onchain; the profile itself is kept in this browser
              for display. For the testnet demo, use a synthetic name.
            </span>
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
          </div>
          <div className="field">
            <span className="label">Services offered</span>
            <div className="checks">
              {SERVICE_TYPES.map((s) => (
                <label key={s.hash} className={`check-pill ${services.includes(s.hash) ? 'on' : ''}`}>
                  <input type="checkbox" checked={services.includes(s.hash)} onChange={() => toggle(s.hash)} />
                  {s.name}
                </label>
              ))}
            </div>
            <span className="help">A verifier checks these claims. Adding a service later requires re-verification.</span>
          </div>
          <div className="field">
            <label htmlFor="pstake">Stake</label>
            <div className="input-suffix">
              <input id="pstake" className="input" inputMode="decimal" value={stake} onChange={(e) => setStake(e.target.value)} />
              <span>USDC</span>
            </div>
            <span className="help">Minimum {usdc(protocol.minStake)}, read from the ProviderRegistry contract.</span>
          </div>
        </div>
      </div>

      <div className="stack">
        <div className="card elevated">
          <span className="eyebrow">About your stake</span>
          <ul className="muted" style={{ paddingLeft: 18, margin: '12px 0 0', fontSize: 14, lineHeight: 1.7 }}>
            <li>Your USDC is held by the ProviderRegistry contract while you are a provider.</li>
            <li>
              To exit, request to unstake: you stop receiving jobs, and after {formatDuration(protocol.unbondingPeriod)} of
              unbonding you can withdraw the full stake — once you have no open jobs.
            </li>
            <li>There is no slashing in this version. Missed deadlines and upheld disputes are recorded in your public reputation.</li>
            <li>Registration is permanent for this wallet. Changing your profile or adding services requires re-verification.</li>
          </ul>
        </div>

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
                call={
                  valid && stakeUnits !== null
                    ? calls.register(profileHash(profile), region.hash, services, stakeUnits)
                    : null
                }
                disabled={!enough || protocol.registryPaused}
                onConfirmed={() => saveProfile(profile)}
                block
              >
                Register as provider
              </TxButton>
            </StepCard>
          </div>
        </NetworkGate>
      </div>
    </div>
  )
}

// ------------------------------------------------------------------------------------------------------------------

function Dashboard({ account, protocol }: { account: AccountState; protocol: ProtocolState }) {
  const { address } = useConnection()
  const providers = useProviders().data
  const requests = useRequests().data
  const now = useNow()
  const me = providers?.find((p) => sameAddress(p.address, address))
  const rec = account.provider
  const label = me ? providerLabel(me) : null
  const unbonding = rec.unstakeAvailableAt > 0n
  const stakeOk = rec.stake >= protocol.minStake

  const { available, active, history } = useMemo(() => {
    const all = requests ?? []
    return {
      available: all.filter(
        (r) =>
          r.request.status === Status.OPEN &&
          now <= r.request.acceptDeadline &&
          !sameAddress(r.request.buyer, address) &&
          (isZeroAddress(r.request.provider) || sameAddress(r.request.provider, address)) &&
          !!me?.capabilities.some((c) => c.toLowerCase() === r.request.serviceType.toLowerCase()),
      ),
      active: all.filter((r) => sameAddress(r.request.provider, address) && r.request.status !== Status.OPEN && !isTerminal(r.request.status)),
      history: all.filter((r) => sameAddress(r.request.provider, address) && isTerminal(r.request.status)),
    }
  }, [requests, address, me, now])

  return (
    <>
      <div className="page-head">
        <div>
          <span className="eyebrow">Provider dashboard</span>
          <h1>{label?.name ?? 'Your provider account'}</h1>
          <div className="row" style={{ marginTop: 12 }}>
            <ProviderStatus record={rec} minStake={protocol.minStake} />
            <span className="faint">
              <RegionName hash={rec.locationHash} />
            </span>
          </div>
        </div>
      </div>

      <Checklist account={account} protocol={protocol} />

      <div className="grid grid-4" style={{ marginTop: 16 }}>
        <Stat label="Stake" value={formatUsdc(rec.stake)} unit="USDC" hint={unbonding ? `Unbonding until ${formatDateTime(rec.unstakeAvailableAt)}` : `Minimum ${usdc(protocol.minStake)}`} />
        <Stat label="Available earnings" value={formatUsdc(account.escrowCredit)} unit="USDC" hint="Settled payments ready to withdraw" />
        <Stat label="Active jobs" value={rec.activeJobs} hint="Accepted and not yet closed" />
        <Stat label="Successful jobs" value={account.reputation.successfulJobs.toString()} hint="Settled with payment" />
      </div>

      {account.escrowCredit > 0n && (
        <div className="banner" style={{ marginTop: 16 }}>
          <div>
            <strong>
              <Usdc amount={account.escrowCredit} /> ready to withdraw
            </strong>
            <p>Payments for settled jobs are credited to you in ClinovaEscrow. Withdrawals are never paused.</p>
          </div>
          <TxButton call={calls.withdrawCredit()}>Withdraw earnings</TxButton>
        </div>
      )}

      <div className="section">
        <div className="section-title">
          <h2>Jobs available to you</h2>
          <span className="faint" style={{ fontSize: 13 }}>Open requests for services you offer</span>
        </div>
        {!requests ? (
          <Skeleton height={80} />
        ) : available.length === 0 ? (
          <Empty>No open requests match your services right now.</Empty>
        ) : (
          <div className="card">
            <RequestTable requests={available} perspective="provider" />
          </div>
        )}
      </div>

      <div className="section">
        <div className="section-title">
          <h2>Your active jobs</h2>
        </div>
        {!requests ? (
          <Skeleton height={80} />
        ) : active.length === 0 ? (
          <Empty>No active jobs.</Empty>
        ) : (
          <div className="card">
            <RequestTable requests={active} perspective="provider" />
          </div>
        )}
      </div>

      <div className="section">
        <div className="section-title">
          <h2>Clinova performance</h2>
          <span className="faint" style={{ fontSize: 13 }}>From ReputationRegistry · cannot be edited by anyone</span>
        </div>
        <div className="card">
          <ReputationPanel reputation={account.reputation} />
        </div>
      </div>

      <div className="section grid grid-2">
        <Capabilities offered={me?.capabilities ?? []} verified={rec.verified} />
        <StakeManagement account={account} protocol={protocol} stakeOk={stakeOk} />
      </div>

      {history.length > 0 && (
        <div className="section">
          <div className="section-title">
            <h2>Completed and closed jobs</h2>
          </div>
          <div className="card">
            <RequestTable requests={history.sort((a, b) => Number(b.id - a.id))} perspective="provider" />
          </div>
        </div>
      )}
    </>
  )
}

function Checklist({ account, protocol }: { account: AccountState; protocol: ProtocolState }) {
  const rec = account.provider
  const unbonding = rec.unstakeAvailableAt > 0n
  const stakeOk = rec.stake >= protocol.minStake
  if (rec.active) return null
  const items: { title: string; done: boolean; body?: ReactNode }[] = [
    { title: 'Registered', done: true },
    {
      title: `Stake at least ${usdc(protocol.minStake)}`,
      done: stakeOk && !unbonding,
      body: unbonding ? 'Your stake is unbonding. Deposit stake again after withdrawing to re-activate.' : 'Top up your stake below.',
    },
    {
      title: 'Verified by a Clinova verifier',
      done: rec.verified,
      body: (
        <>
          A verifier reviews your business profile and claimed services offchain, then verifies your wallet onchain. Share
          your wallet address with the Clinova verification team. This page updates automatically.
        </>
      ),
    },
    {
      title: 'Activate to start receiving requests',
      done: rec.active,
      body:
        rec.verified && stakeOk && !unbonding ? (
          <TxButton call={calls.activate()}>Activate</TxButton>
        ) : (
          'Available once you are verified and staked.'
        ),
    },
  ]
  const currentIdx = items.findIndex((i) => !i.done)
  return (
    <div className="steps">
      {items.map((it, i) => (
        <StepCard key={it.title} index={i + 1} total={items.length} title={it.title} status={it.done ? 'done' : i === currentIdx ? 'current' : 'todo'}>
          {it.body}
        </StepCard>
      ))}
    </div>
  )
}

function Capabilities({ offered, verified }: { offered: Hex[]; verified: boolean }) {
  const [adding, setAdding] = useState<Hex | ''>('')
  const notOffered = SERVICE_TYPES.filter((s) => !offered.some((o) => o.toLowerCase() === s.hash))
  return (
    <div className="card stack">
      <h3>Services you offer</h3>
      {offered.length === 0 ? (
        <span className="faint">None listed.</span>
      ) : (
        offered.map((h) => (
          <div key={h} className="spread">
            <ServiceName hash={h} />
            <TxButton call={calls.removeCapability(h)} variant="small" confirm="Stop offering this service? Your verification is kept.">
              Remove
            </TxButton>
          </div>
        ))
      )}
      {notOffered.length > 0 && (
        <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--border-moss)', paddingTop: 16 }}>
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
            {verified && (
              <span className="help" style={{ color: 'var(--warn)' }}>
                Adding a service removes your verification and pauses new jobs until a verifier re-verifies you.
              </span>
            )}
          </div>
          <TxButton
            call={adding ? calls.addCapability(adding) : null}
            variant="ghost"
            confirm={verified ? 'Adding a service will remove your verification until re-verified. Continue?' : undefined}
            onConfirmed={() => setAdding('')}
          >
            Add service
          </TxButton>
        </div>
      )}
    </div>
  )
}

function StakeManagement({ account, protocol, stakeOk }: { account: AccountState; protocol: ProtocolState; stakeOk: boolean }) {
  const rec = account.provider
  const now = useNow()
  const [amount, setAmount] = useState('')
  const units = parseUsdc(amount)
  const unbonding = rec.unstakeAvailableAt > 0n
  const ready = unbonding && now >= rec.unstakeAvailableAt
  const approved = units !== null && units > 0n && account.allowanceRegistry >= units

  return (
    <div className="card stack">
      <h3>Stake and availability</h3>
      <dl className="kv">
        <dt>Current stake</dt>
        <dd>
          <Usdc amount={rec.stake} />
        </dd>
        <dt>Unbonding period</dt>
        <dd>{formatDuration(protocol.unbondingPeriod)}</dd>
        {unbonding && (
          <>
            <dt>Withdrawable</dt>
            <dd>{ready ? 'Now' : formatDateTime(rec.unstakeAvailableAt)}</dd>
          </>
        )}
      </dl>

      {unbonding ? (
        <div className="stack" style={{ gap: 8 }}>
          <p className="muted" style={{ margin: 0, fontSize: 14 }}>
            {rec.activeJobs > 0
              ? `You still have ${rec.activeJobs} open job(s). Stake can be withdrawn once they close.`
              : ready
                ? 'Your unbonding period is over. Withdraw the full stake to your wallet.'
                : 'Your stake is unbonding. You are not receiving new jobs.'}
          </p>
          <TxButton call={calls.withdrawStake()} disabled={!ready || rec.activeJobs > 0}>
            Withdraw stake
          </TxButton>
        </div>
      ) : (
        <>
          <div className="stack" style={{ gap: 8 }}>
            <div className="field">
              <label htmlFor="topup">Add stake</label>
              <div className="input-suffix">
                <input id="topup" className="input" inputMode="decimal" value={amount} placeholder="0" onChange={(e) => setAmount(e.target.value)} />
                <span>USDC</span>
              </div>
              {!stakeOk && <span className="help">At least {usdc(protocol.minStake - rec.stake)} more is needed to be eligible.</span>}
            </div>
            {!approved ? (
              <TxButton call={units && units > 0n ? calls.approveRegistry(units) : null} variant="ghost" disabled={protocol.registryPaused}>
                Step 1 of 2 · Approve {units && units > 0n ? usdc(units) : 'USDC'}
              </TxButton>
            ) : (
              <TxButton call={calls.depositStake(units!)} variant="ghost" disabled={protocol.registryPaused} onConfirmed={() => setAmount('')}>
                Step 2 of 2 · Deposit {usdc(units!)}
              </TxButton>
            )}
          </div>
          <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--border-moss)', paddingTop: 16 }}>
            {rec.active && (
              <TxButton call={calls.deactivate()} variant="ghost">
                Pause new requests
              </TxButton>
            )}
            {rec.stake > 0n && (
              <TxButton
                call={calls.requestUnstake()}
                variant="danger"
                confirm={`Start unbonding? You will stop receiving requests immediately and can withdraw after ${formatDuration(protocol.unbondingPeriod)}.`}
              >
                Request unstake
              </TxButton>
            )}
          </div>
        </>
      )}
      <Link to="/discover" className="link" style={{ alignSelf: 'flex-start', fontSize: 14 }}>
        See how buyers see you →
      </Link>
    </div>
  )
}
