import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { formatEther } from 'viem'
import { useAccount } from 'wagmi'
import { DashHeader, HowItWorks, JobList, MetricStrip, Panel, Tabs } from '../components/Dashboard'
import { TxButton } from '../components/Tx'
import { LoadError, Skeleton, Usdc } from '../components/ui'
import { NetworkGate } from '../components/Wallet'
import { useAccountState, useNow, useRequests } from '../hooks/useClinova'
import { calls } from '../lib/contracts/calls'
import { EscrowState, isTerminal, Status } from '../lib/contracts/types'
import { addressUrl, formatUsdc, sameAddress, shortAddress } from '../lib/format'
import { jobState } from '../lib/jobs'

const HOW_IT_WORKS: [string, string][] = [
  ['Choose a test and provider', 'Pick a diagnostic service and a verified provider — or open it to any eligible one.'],
  ['Fund the request', 'Approve and escrow the fixed USDC price. Nothing is paid out yet.'],
  ['Provider performs the service', 'They accept, start and submit a proof-of-service commitment.'],
  ['Confirm or dispute', 'Payment is released only when you confirm or a verifier approves.'],
]

type Tab = 'attention' | 'active' | 'completed' | 'all'

export function Buyer() {
  const { address } = useAccount()
  const requests = useRequests()
  const account = useAccountState().data
  const now = useNow()
  const [tab, setTab] = useState<Tab | null>(null)

  const mine = useMemo(
    () => (requests.data ?? []).filter((r) => sameAddress(r.request.buyer, address)).sort((a, b) => Number(b.id - a.id)),
    [requests.data, address],
  )

  if (!address)
    return (
      <div className="container page">
        <div className="intro-grid">
          <div>
            <span className="eyebrow">Healthcare businesses</span>
            <h1 className="intro-title">Diagnostics on demand, paid only when delivered.</h1>
            <p className="intro-text">
              Extend your telemedicine platform or healthcare application into real-world diagnostics. Reserve tests from verified labs and clinics across the network — your USDC stays in escrow until you confirm
              the service or an authorized verifier approves the proof.
            </p>
            <div className="panel connect-panel">
              <h3>Connect your organisation’s wallet</h3>
              <p className="muted">You’ll need test USDC for payments and a little Arbitrum Sepolia ETH for network fees.</p>
              <NetworkGate>{null}</NetworkGate>
            </div>
          </div>
          <HowItWorks title="How it works for healthcare businesses" steps={HOW_IT_WORKS} />
        </div>
      </div>
    )

  const loading = !requests.data
  const attention = mine.filter((r) => jobState(r, 'buyer', now).actionNeeded)
  const active = mine.filter((r) => !isTerminal(r.request.status))
  const completed = mine.filter((r) => isTerminal(r.request.status))
  const escrowed = mine.filter((r) => r.deposit.state === EscrowState.FUNDED).reduce((s, r) => s + r.request.price, 0n)
  const totalSettled = mine.filter((r) => r.request.status === Status.SETTLED).reduce((s, r) => s + r.request.price, 0n)
  const lists = { attention, active, completed, all: mine }
  const currentTab: Tab = tab ?? (attention.length > 0 ? 'attention' : 'active')

  return (
    <div className="container page">
      <DashHeader
        eyebrow="Healthcare business"
        title="Diagnostic requests"
        tile={<img src="/brand/favicon-48.png" alt="" width={26} height={26} />}
        meta={
          <>
            <a className="mono link" href={addressUrl(address)} target="_blank" rel="noreferrer">
              {shortAddress(address)} ↗
            </a>
            {account && (
              <span>
                <Usdc amount={account.usdcBalance} /> available
              </span>
            )}
          </>
        }
        actions={
          <>
            <Link to="/discover" className="btn btn-ghost">
              Browse providers
            </Link>
            <Link to="/buyer/new" className="btn btn-primary">
              New request
            </Link>
          </>
        }
      />

      {requests.error && <LoadError error={requests.error} />}

      {account && account.escrowCredit > 0n && (
        <div className="callout">
          <div>
            <span className="callout-label">Refund available</span>
            <strong>
              <Usdc amount={account.escrowCredit} />
            </strong>
            <p>Refunds from cancelled, expired or disputed requests are held for you in ClinovaEscrow until withdrawn.</p>
          </div>
          <TxButton call={calls.withdrawCredit()}>Withdraw to wallet</TxButton>
        </div>
      )}

      <MetricStrip
        loading={loading}
        items={[
          { label: 'Needs your review', value: attention.length, hint: 'Requests waiting on you', highlight: attention.length > 0 },
          { label: 'Active requests', value: active.length, hint: 'Funded and in progress' },
          { label: 'Escrowed now', value: formatUsdc(escrowed), unit: 'USDC', hint: 'Held by ClinovaEscrow' },
          { label: 'Total settled', value: formatUsdc(totalSettled), unit: 'USDC', hint: 'Paid after accepted proof' },
        ]}
      />

      <div className="dash-grid">
        <div className="dash-main">
          {!loading && mine.length === 0 ? (
            <Panel title="Your first request">
              <div className="first-run">
                <p>
                  Create a request for a diagnostic service. The fixed price is held in escrow and released only after the
                  service is confirmed.
                </p>
                <div className="row">
                  <Link to="/buyer/new" className="btn btn-primary">
                    Create a request
                  </Link>
                  <Link to="/discover" className="btn btn-ghost">
                    Browse providers
                  </Link>
                </div>
              </div>
            </Panel>
          ) : (
            <Panel title="Requests" subtitle="Every request you have funded, with what happens next." flush>
              <Tabs<Tab>
                value={currentTab}
                onChange={setTab}
                tabs={[
                  { id: 'attention', label: 'Needs attention', count: attention.length, attention: true },
                  { id: 'active', label: 'Active', count: active.length },
                  { id: 'completed', label: 'Completed', count: completed.length },
                  { id: 'all', label: 'All', count: mine.length },
                ]}
              />
              {loading ? (
                <div style={{ padding: 20 }}>
                  <Skeleton height={64} />
                </div>
              ) : (
                <JobList
                  jobs={lists[currentTab]}
                  perspective="buyer"
                  now={now}
                  empty={
                    currentTab === 'attention'
                      ? 'Nothing needs your attention. You’ll see requests here when a proof is ready to review.'
                      : currentTab === 'active'
                        ? 'No active requests.'
                        : 'No requests here yet.'
                  }
                />
              )}
            </Panel>
          )}
        </div>

        <aside className="dash-side">
          <Panel title="Wallet" subtitle="Balances on Arbitrum Sepolia">
            {account ? (
              <dl className="kv">
                <dt>USDC</dt>
                <dd>
                  <Usdc amount={account.usdcBalance} />
                </dd>
                <dt>ETH for fees</dt>
                <dd>{Number(formatEther(account.ethBalance)).toFixed(5)} ETH</dd>
                <dt>Refundable</dt>
                <dd>
                  <Usdc amount={account.escrowCredit} />
                </dd>
              </dl>
            ) : (
              <Skeleton height={80} />
            )}
            <div className="panel-links">
              <a className="link ext" href="https://faucet.circle.com" target="_blank" rel="noreferrer">
                Test USDC faucet
              </a>
              <a className="link ext" href="https://www.alchemy.com/faucets/arbitrum-sepolia" target="_blank" rel="noreferrer">
                Test ETH faucet
              </a>
            </div>
          </Panel>
          <Panel title="How payment works">
            <ul className="terms">
              <li>The price is fixed when you create the request and held in escrow.</li>
              <li>It is released to the provider only when you confirm or a verifier approves the proof.</li>
              <li>If no provider accepts, or the provider misses the deadline, you can reclaim the full amount.</li>
              <li>Disputes are decided by an authorized verifier. If none acts in time, you are refunded.</li>
            </ul>
          </Panel>
        </aside>
      </div>
    </div>
  )
}
