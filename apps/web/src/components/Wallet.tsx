import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useConnect, useConnection, useConnectors, useDisconnect, useSwitchChain } from 'wagmi'
import { CLINOVA_CHAIN } from '../config/contracts'
import { useAccountState, useWrongNetwork } from '../hooks/useClinova'
import { addressUrl, formatUsdc, shortAddress } from '../lib/format'
import { formatEther } from 'viem'

function ConnectOptions({ onDone }: { onDone?: () => void }) {
  const connectors = useConnectors()
  const connect = useConnect()
  // EIP-6963 wallets announce themselves; hide the generic fallback when a named wallet is present.
  const named = connectors.filter((c) => c.id !== 'injected')
  const list = named.length > 0 ? named : connectors
  const hasWallet = typeof window !== 'undefined' && ('ethereum' in window || named.length > 0)

  if (!hasWallet)
    return (
      <div className="stack" style={{ gap: 8, fontSize: 14 }}>
        <strong>No browser wallet found</strong>
        <span className="muted">Install a wallet such as MetaMask or Rabby, then reload this page.</span>
      </div>
    )
  return (
    <div className="stack" style={{ gap: 8 }}>
      {list.map((c) => (
        <button
          key={c.uid}
          type="button"
          className="btn-small btn-block"
          style={{ justifyContent: 'flex-start', display: 'flex', gap: 10, alignItems: 'center' }}
          disabled={connect.isPending}
          onClick={() => connect.mutate({ connector: c, chainId: CLINOVA_CHAIN.id }, { onSuccess: onDone })}
        >
          {c.icon && <img src={c.icon} alt="" width={18} height={18} />}
          {c.id === 'injected' ? 'Browser wallet' : c.name}
        </button>
      ))}
      {connect.error && (
        <span style={{ fontSize: 13, color: 'var(--danger)' }}>
          {/rejected|denied/i.test(connect.error.message) ? 'Connection cancelled in the wallet.' : connect.error.message.split('\n')[0]}
        </span>
      )}
    </div>
  )
}

function usePopover() {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false)
    document.addEventListener('mousedown', onDoc)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDoc)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])
  return [open, setOpen, ref] as const
}

export function WalletButton() {
  const { address, isConnected } = useConnection()
  const disconnect = useDisconnect()
  const wrong = useWrongNetwork()
  const account = useAccountState().data
  const [open, setOpen, popRef] = usePopover()
  // Close the menu once a connection is established (derived-state pattern; no effect needed).
  const [wasConnected, setWasConnected] = useState(isConnected)
  if (isConnected !== wasConnected) {
    setWasConnected(isConnected)
    if (isConnected) setOpen(false)
  }

  return (
    <div className="wallet-menu" ref={popRef}>
      {isConnected && address ? (
        <button type="button" className="btn btn-ghost" style={{ padding: '8px 16px' }} onClick={() => setOpen(!open)}>
          <span className={`net-pill ${wrong ? 'wrong' : ''}`} style={{ border: 'none', padding: 0, display: 'inline-flex' }} />
          <span className="mono" style={{ textTransform: 'none', letterSpacing: 0 }}>
            {shortAddress(address)}
          </span>
        </button>
      ) : (
        <button type="button" className="btn btn-primary" style={{ padding: '10px 20px' }} onClick={() => setOpen(!open)}>
          Connect wallet
        </button>
      )}
      {open && (
        <div className="wallet-pop">
          {isConnected && address ? (
            <div className="stack" style={{ gap: 12, fontSize: 14 }}>
              <div>
                <div className="eyebrow">Connected</div>
                <a className="link mono" href={addressUrl(address)} target="_blank" rel="noreferrer">
                  {shortAddress(address)} ↗
                </a>
              </div>
              <div className="spread">
                <span className="muted">Network</span>
                <span>{wrong ? <span style={{ color: 'var(--warn)' }}>Wrong network</span> : 'Arbitrum Sepolia'}</span>
              </div>
              {account && (
                <>
                  <div className="spread">
                    <span className="muted">USDC</span>
                    <span>{formatUsdc(account.usdcBalance)}</span>
                  </div>
                  <div className="spread">
                    <span className="muted">ETH (gas)</span>
                    <span>{Number(formatEther(account.ethBalance)).toFixed(5)}</span>
                  </div>
                  <div className="spread">
                    <span className="muted">Roles</span>
                    <span>
                      {[
                        account.provider.registered && 'Provider',
                        account.isMarketplaceVerifier && 'Verifier',
                        account.isPauser && 'Pauser',
                      ]
                        .filter(Boolean)
                        .join(' · ') || 'Buyer'}
                    </span>
                  </div>
                </>
              )}
              <button type="button" className="btn-small btn-block" onClick={() => (disconnect.mutate(), setOpen(false))}>
                Disconnect
              </button>
            </div>
          ) : (
            <ConnectOptions onDone={() => setOpen(false)} />
          )}
        </div>
      )}
    </div>
  )
}

/** Renders children only when a wallet is connected on Arbitrum Sepolia; otherwise the step needed to get there. */
export function NetworkGate({ children, compact }: { children: ReactNode; compact?: boolean }) {
  const { isConnected } = useConnection()
  const wrong = useWrongNetwork()
  const switchChain = useSwitchChain()
  const [open, setOpen, popRef] = usePopover()

  if (!isConnected)
    return (
      <div className="wallet-menu" ref={popRef} style={{ display: compact ? 'inline-block' : 'block' }}>
        <button type="button" className="btn btn-primary" onClick={() => setOpen(!open)}>
          Connect wallet
        </button>
        {open && (
          <div className="wallet-pop" style={{ left: 0, right: 'auto' }}>
            <ConnectOptions onDone={() => setOpen(false)} />
          </div>
        )}
      </div>
    )
  if (wrong)
    return (
      <div className="stack" style={{ gap: 6 }}>
        <button
          type="button"
          className="btn btn-primary"
          disabled={switchChain.isPending}
          onClick={() => switchChain.mutate({ chainId: CLINOVA_CHAIN.id })}
        >
          Switch to Arbitrum Sepolia
        </button>
        {!compact && <span className="faint" style={{ fontSize: 13 }}>Clinova currently runs on Arbitrum Sepolia.</span>}
      </div>
    )
  return <>{children}</>
}

export function WrongNetworkBanner() {
  const wrong = useWrongNetwork()
  const switchChain = useSwitchChain()
  if (!wrong) return null
  return (
    <div className="container" style={{ marginTop: 16 }}>
      <div className="banner warn">
        <div>
          <strong>Clinova currently runs on Arbitrum Sepolia.</strong>
          <p>Your wallet is on another network. You can browse, but transactions are disabled until you switch.</p>
        </div>
        <button
          type="button"
          className="btn btn-primary"
          disabled={switchChain.isPending}
          onClick={() => switchChain.mutate({ chainId: CLINOVA_CHAIN.id })}
        >
          Switch network
        </button>
      </div>
    </div>
  )
}
