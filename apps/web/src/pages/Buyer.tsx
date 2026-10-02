import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import { useConnection } from 'wagmi'
import { RequestTable } from '../components/Request'
import { TxButton } from '../components/Tx'
import { Empty, LoadError, Skeleton, Stat, Usdc } from '../components/ui'
import { NetworkGate } from '../components/Wallet'
import { useAccountState, useRequests } from '../hooks/useClinova'
import { calls } from '../lib/contracts/calls'
import { EscrowState, isTerminal, Status } from '../lib/contracts/types'
import { formatUsdc, sameAddress } from '../lib/format'

export function Buyer() {
  const { address } = useConnection()
  const requests = useRequests()
  const account = useAccountState().data

  const mine = useMemo(
    () => (requests.data ?? []).filter((r) => sameAddress(r.request.buyer, address)).sort((a, b) => Number(b.id - a.id)),
    [requests.data, address],
  )
  const active = mine.filter((r) => !isTerminal(r.request.status))
  const settled = mine.filter((r) => r.request.status === Status.SETTLED)
  const escrowed = mine.filter((r) => r.deposit.state === EscrowState.FUNDED).reduce((s, r) => s + r.request.price, 0n)
  const totalSettled = settled.reduce((s, r) => s + r.request.price, 0n)

  return (
    <div className="container page">
      <div className="page-head">
        <div>
          <span className="eyebrow">Healthcare businesses</span>
          <h1>Your diagnostic requests</h1>
          <p>Reserve capacity, follow each job through verification, and see exactly where your USDC is.</p>
        </div>
        {address && (
          <Link to="/buyer/new" className="btn btn-primary">
            New request
          </Link>
        )}
      </div>

      {!address ? (
        <div className="card stack" style={{ maxWidth: 560 }}>
          <h3>Connect a wallet to see your requests</h3>
          <p className="muted" style={{ margin: 0 }}>
            Your wallet is your organisation’s account on Clinova. You’ll need test USDC for payments and a little
            Arbitrum Sepolia ETH for network fees.
          </p>
          <NetworkGate>{null}</NetworkGate>
        </div>
      ) : (
        <>
          {requests.error && <LoadError error={requests.error} />}
          <div className="grid grid-4">
            <Stat label="Active requests" value={requests.data ? active.length : <Skeleton width={40} height={32} />} />
            <Stat label="Settled requests" value={requests.data ? settled.length : <Skeleton width={40} height={32} />} />
            <Stat
              label="Escrowed now"
              value={requests.data ? formatUsdc(escrowed) : <Skeleton width={80} height={32} />}
              unit="USDC"
              hint="Held by ClinovaEscrow for your open requests"
            />
            <Stat
              label="Total settled"
              value={requests.data ? formatUsdc(totalSettled) : <Skeleton width={80} height={32} />}
              unit="USDC"
              hint="Paid to providers after accepted proof"
            />
          </div>

          {account && account.escrowCredit > 0n && (
            <div className="banner" style={{ marginTop: 16 }}>
              <div>
                <strong>
                  <Usdc amount={account.escrowCredit} /> available to withdraw
                </strong>
                <p>Refunds from cancelled, expired or disputed requests are credited here until you withdraw them.</p>
              </div>
              <TxButton call={calls.withdrawCredit()}>Withdraw to wallet</TxButton>
            </div>
          )}

          <div className="section">
            <div className="section-title">
              <h2>Requests</h2>
              <Link to="/discover" className="link">
                Browse providers
              </Link>
            </div>
            {!requests.data ? (
              <Skeleton height={120} />
            ) : mine.length === 0 ? (
              <Empty>
                No requests from this wallet yet. <Link to="/buyer/new" className="link">Create your first request</Link>.
              </Empty>
            ) : (
              <div className="card">
                <RequestTable requests={mine} perspective="buyer" />
              </div>
            )}
          </div>
        </>
      )}
    </div>
  )
}
