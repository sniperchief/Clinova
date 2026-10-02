import { useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { getAddress, isAddress, parseEventLogs, type Address, type Hex } from 'viem'
import { useConnection } from 'wagmi'
import { REGIONS, SERVICE_TYPES } from '../config/catalog'
import { providerLabel } from '../lib/providerLabel'
import { StepCard, TxButton } from '../components/Tx'
import { Addr, Usdc } from '../components/ui'
import { NetworkGate } from '../components/Wallet'
import { useAccountState, useNow, useProtocol, useProviders } from '../hooks/useClinova'
import { serviceMarketplaceAbi } from '../lib/contracts/abis'
import { calls } from '../lib/contracts/calls'
import {
  formatDateTime,
  formatDuration,
  fromDateTimeLocal,
  parseUsdc,
  sameAddress,
  toDateTimeLocal,
  usdc,
  ZERO_ADDRESS,
} from '../lib/format'

// Contract windows (ServiceMarketplace constants). A safety margin keeps a valid form valid when the
// transaction is mined a few minutes later.
const HOUR = 3600
const MARGIN = 10 * 60
const MIN_ACCEPT = HOUR
const MAX_ACCEPT = 7 * 24 * HOUR
const MIN_SERVICE = 6 * HOUR
const MAX_SERVICE = 30 * 24 * HOUR

export function NewRequest() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { address } = useConnection()
  const protocol = useProtocol().data
  const providers = useProviders().data
  const account = useAccountState().data

  const presetProvider = params.get('provider')
  const preset = presetProvider && isAddress(presetProvider) ? getAddress(presetProvider) : ''
  const presetCaps = providers?.find((p) => sameAddress(p.address, preset))?.capabilities ?? []

  const now = Number(useNow())
  const [serviceChoice, setService] = useState<Hex | ''>('')
  const service: Hex = serviceChoice || presetCaps[0] || SERVICE_TYPES[0].hash
  const [provider, setProvider] = useState<Address | ''>(preset)
  const [region, setRegion] = useState<Hex>(REGIONS[0].hash)
  const [price, setPrice] = useState('5')
  const [acceptBy, setAcceptBy] = useState(toDateTimeLocal(now + 24 * HOUR))
  const [serviceBy, setServiceBy] = useState(toDateTimeLocal(now + 4 * 24 * HOUR))

  const eligible = useMemo(() => (providers ?? []).filter((p) => p.eligibleFor(service)), [providers, service])
  const chosenProvider = providers?.find((p) => sameAddress(p.address, provider))

  // ---- validation (UX only; the contract re-validates everything)
  const errors: Record<string, string> = {}
  const priceUnits = parseUsdc(price)
  if (priceUnits === null) errors.price = 'Enter an amount like 25 or 25.50 (up to 6 decimals).'
  else if (protocol && priceUnits < protocol.minPrice) errors.price = `Minimum payment is ${usdc(protocol.minPrice)}.`
  else if (priceUnits > 2n ** 128n - 1n) errors.price = 'Amount is too large.'
  const a = fromDateTimeLocal(acceptBy)
  const s = fromDateTimeLocal(serviceBy)
  if (a === null) errors.acceptBy = 'Choose a date and time.'
  else if (a < now + MIN_ACCEPT + MARGIN) errors.acceptBy = 'Must be at least 1 hour 10 minutes from now.'
  else if (a > now + MAX_ACCEPT - MARGIN) errors.acceptBy = 'Must be within 7 days.'
  if (s === null) errors.serviceBy = 'Choose a date and time.'
  else if (a !== null && s < a + MIN_SERVICE) errors.serviceBy = 'Must be at least 6 hours after the acceptance deadline.'
  else if (a !== null && s > a + MAX_SERVICE) errors.serviceBy = 'Must be within 30 days of the acceptance deadline.'
  if (provider && sameAddress(provider, address)) errors.provider = 'You cannot direct a request to your own wallet.'
  if (provider && chosenProvider && !chosenProvider.eligibleFor(service))
    errors.provider = 'This provider is not currently eligible for the selected service. Choose another or leave it open.'
  if (provider && !chosenProvider && providers) errors.provider = 'This address is not a registered provider.'
  const valid = Object.keys(errors).length === 0 && priceUnits !== null && a !== null && s !== null

  const createCall =
    valid && priceUnits !== null
      ? calls.createRequest({
          directedProvider: provider || ZERO_ADDRESS,
          serviceType: service,
          locationHash: region,
          price: priceUnits,
          acceptDeadline: BigInt(a!),
          serviceDeadline: BigInt(s!),
        })
      : null

  const approved = !!account && priceUnits !== null && account.allowanceMarketplace >= priceUnits
  const enoughUsdc = !!account && priceUnits !== null && account.usdcBalance >= priceUnits
  const hasGas = !!account && account.ethBalance > 0n
  const paused = protocol?.marketplacePaused

  const serviceInfo = SERVICE_TYPES.find((x) => x.hash === service)
  const regionInfo = REGIONS.find((x) => x.hash === region)

  return (
    <div className="container page">
      <div className="page-head">
        <div>
          <Link to="/buyer" className="link">
            ← Requests
          </Link>
          <h1 style={{ marginTop: 16 }}>New diagnostic request</h1>
          <p>The payment is fixed when you create the request and is held in escrow until the service is verified.</p>
        </div>
      </div>

      <div className="split">
        <div className="card stack" style={{ gap: 22 }}>
          <div className="field">
            <label htmlFor="service">Diagnostic service</label>
            <select id="service" className="input" value={service} onChange={(e) => setService(e.target.value as Hex)}>
              {SERVICE_TYPES.map((x) => (
                <option key={x.hash} value={x.hash}>
                  {x.name} ({x.short})
                </option>
              ))}
            </select>
            <span className="help">
              Catalog code <span className="mono">{serviceInfo?.code}</span>. Only the code is recorded — never patient
              details.
            </span>
          </div>

          <div className="field">
            <label htmlFor="provider">Provider</label>
            <select id="provider" className="input" value={provider} onChange={(e) => setProvider(e.target.value as Address)}>
              <option value="">Any eligible provider (open request)</option>
              {eligible.map((p) => (
                <option key={p.address} value={p.address}>
                  {providerLabel(p).name ?? 'Unlabelled provider'} · {p.address.slice(0, 8)}…
                </option>
              ))}
              {provider && !eligible.some((p) => sameAddress(p.address, provider)) && (
                <option value={provider}>{provider.slice(0, 10)}… (not eligible)</option>
              )}
            </select>
            {errors.provider ? (
              <span className="error">{errors.provider}</span>
            ) : (
              <span className="help">
                {eligible.length} provider{eligible.length === 1 ? '' : 's'} currently eligible for this service. An open
                request can be accepted by any of them.
              </span>
            )}
          </div>

          <div className="field">
            <label htmlFor="region">Service area</label>
            <select id="region" className="input" value={region} onChange={(e) => setRegion(e.target.value as Hex)}>
              {REGIONS.map((r) => (
                <option key={r.hash} value={r.hash}>
                  {r.name}
                </option>
              ))}
            </select>
            <span className="help">A coarse city or zone code — never a patient address. Informational; providers see it.</span>
          </div>

          <div className="field">
            <label htmlFor="price">Payment</label>
            <div className="input-suffix">
              <input
                id="price"
                className="input"
                inputMode="decimal"
                value={price}
                onChange={(e) => setPrice(e.target.value)}
                aria-invalid={!!errors.price}
              />
              <span>USDC</span>
            </div>
            {errors.price ? (
              <span className="error">{errors.price}</span>
            ) : (
              <span className="help">Fixed price, paid in full to the provider on settlement. No protocol fee.</span>
            )}
          </div>

          <div className="grid grid-2">
            <div className="field">
              <label htmlFor="acceptBy">Provider must accept by</label>
              <input id="acceptBy" type="datetime-local" className="input" value={acceptBy} onChange={(e) => setAcceptBy(e.target.value)} />
              {errors.acceptBy ? <span className="error">{errors.acceptBy}</span> : <span className="help">1 hour to 7 days from now.</span>}
            </div>
            <div className="field">
              <label htmlFor="serviceBy">Service completed by</label>
              <input id="serviceBy" type="datetime-local" className="input" value={serviceBy} onChange={(e) => setServiceBy(e.target.value)} />
              {errors.serviceBy ? (
                <span className="error">{errors.serviceBy}</span>
              ) : (
                <span className="help">6 hours to 30 days after the acceptance deadline.</span>
              )}
            </div>
          </div>
        </div>

        <div className="stack">
          <div className="card elevated">
            <span className="eyebrow">Review</span>
            <dl className="kv" style={{ marginTop: 14 }}>
              <dt>Service</dt>
              <dd>{serviceInfo?.name}</dd>
              <dt>Provider</dt>
              <dd>{provider ? <Addr address={provider} label={chosenProvider ? providerLabel(chosenProvider).name : null} /> : 'Any eligible provider'}</dd>
              <dt>Area</dt>
              <dd>{regionInfo?.name}</dd>
              <dt>Payment</dt>
              <dd>{priceUnits !== null ? <Usdc amount={priceUnits} /> : '—'}</dd>
              <dt>Accept by</dt>
              <dd>{a ? formatDateTime(a) : '—'}</dd>
              <dt>Complete by</dt>
              <dd>{s ? formatDateTime(s) : '—'}</dd>
              {protocol && (
                <>
                  <dt>Review window</dt>
                  <dd>{formatDuration(protocol.reviewPeriod)} after proof is submitted</dd>
                </>
              )}
            </dl>
            <p className="notice" style={{ marginTop: 16 }}>
              If no provider accepts in time, or the provider misses the service deadline, you can reclaim the full
              amount. Payment is only released after you confirm or a verifier approves the proof.
            </p>
          </div>

          <NetworkGate>
            <div className="steps">
              {paused && (
                <div className="banner warn">
                  <div>
                    <strong>New requests are paused.</strong>
                    <p>Clinova is temporarily paused. Please try again later.</p>
                  </div>
                </div>
              )}
              {account && priceUnits !== null && !enoughUsdc && (
                <div className="banner bad">
                  <div>
                    <strong>Not enough USDC.</strong>
                    <p>
                      This wallet holds <Usdc amount={account.usdcBalance} />. Get test USDC from{' '}
                      <a className="link ext" href="https://faucet.circle.com" target="_blank" rel="noreferrer">
                        faucet.circle.com
                      </a>{' '}
                      (Arbitrum Sepolia).
                    </p>
                  </div>
                </div>
              )}
              {account && !hasGas && (
                <div className="banner bad">
                  <div>
                    <strong>No ETH for network fees.</strong>
                    <p>Add a small amount of Arbitrum Sepolia ETH from a faucet.</p>
                  </div>
                </div>
              )}
              <StepCard
                index={1}
                total={2}
                title="Approve USDC"
                status={approved ? 'done' : valid ? 'current' : 'todo'}
                description={
                  approved
                    ? 'The marketplace may move this exact amount into escrow.'
                    : `Allow the Clinova marketplace to move exactly ${priceUnits !== null ? usdc(priceUnits) : 'the payment'} from your wallet into escrow. Nothing moves yet.`
                }
              >
                <TxButton call={priceUnits !== null ? calls.approveMarketplace(priceUnits) : null} disabled={!enoughUsdc || paused} block>
                  Approve {priceUnits !== null ? usdc(priceUnits) : 'USDC'}
                </TxButton>
              </StepCard>
              <StepCard
                index={2}
                total={2}
                title="Create request and fund escrow"
                status={approved && valid ? 'current' : 'todo'}
                description="One transaction creates the request and moves the USDC into ClinovaEscrow."
              >
                <TxButton
                  call={createCall}
                  disabled={!enoughUsdc || paused}
                  block
                  onConfirmed={(receipt) => {
                    const [created] = parseEventLogs({
                      abi: serviceMarketplaceAbi,
                      eventName: 'ServiceRequestCreated',
                      logs: receipt.logs,
                    })
                    navigate(created ? `/requests/${created.args.id}` : '/buyer')
                  }}
                >
                  Create request
                </TxButton>
              </StepCard>
            </div>
          </NetworkGate>
        </div>
      </div>
    </div>
  )
}
