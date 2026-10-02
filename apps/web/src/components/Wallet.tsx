import { useConnectModal } from '@rainbow-me/rainbowkit'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { formatEther } from 'viem'
import { useAccount, useDisconnect, useSwitchChain } from 'wagmi'
import { CLINOVA_CHAIN } from '../config/contracts'
import { useAccountState, useWrongNetwork } from '../hooks/useClinova'
import { addressUrl, formatUsdc, shortAddress } from '../lib/format'

/** Opens RainbowKit's wallet picker. */
function ConnectButton({ block, onBeforeOpen, label = 'Connect wallet' }: { block?: boolean; onBeforeOpen?: () => void; label?: string }) {
  const { openConnectModal } = useConnectModal()
  return (
    <button
      type="button"
      className={`btn btn-primary ${block ? 'btn-block' : ''}`}
      onClick={() => {
        onBeforeOpen?.()
        openConnectModal?.()
      }}
    >
      {label}
    </button>
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

/** Wallet details when connected, or a connect button. Used in the desktop menu and the mobile menu. */
export function WalletPanel({ onDone }: { onDone?: () => void }) {
  const { address, isConnected } = useAccount()
  const { disconnect } = useDisconnect()
  const { switchChain, isPending } = useSwitchChain()
  const wrong = useWrongNetwork()
  const account = useAccountState().data

  if (!isConnected || !address)
    return (
      <div className="stack" style={{ gap: 10 }}>
        <p className="muted" style={{ margin: 0, fontSize: 14 }}>
          Connect a wallet on Arbitrum Sepolia to create requests, provide services or verify.
        </p>
        <ConnectButton block onBeforeOpen={onDone} />
      </div>
    )
  return (
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
              {[account.provider.registered && 'Provider', account.isMarketplaceVerifier && 'Verifier', account.isPauser && 'Pauser']
                .filter(Boolean)
                .join(' · ') || 'Buyer'}
            </span>
          </div>
        </>
      )}
      {wrong && (
        <button type="button" className="btn btn-primary btn-block" disabled={isPending} onClick={() => switchChain({ chainId: CLINOVA_CHAIN.id })}>
          Switch to Arbitrum Sepolia
        </button>
      )}
      <button
        type="button"
        className="btn-small btn-block"
        onClick={() => {
          disconnect()
          onDone?.()
        }}
      >
        Disconnect
      </button>
    </div>
  )
}

/** Nav-bar wallet control: RainbowKit picker to connect; Clinova account menu once connected. */
export function WalletButton() {
  const { address, isConnected } = useAccount()
  const wrong = useWrongNetwork()
  const [open, setOpen, popRef] = usePopover()

  if (!isConnected || !address) return <ConnectButton />
  return (
    <div className="wallet-menu" ref={popRef}>
      <button type="button" className="btn btn-ghost" style={{ padding: '8px 16px' }} onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className={`net-pill ${wrong ? 'wrong' : ''}`} style={{ border: 'none', padding: 0, display: 'inline-flex' }} />
        <span className="mono" style={{ textTransform: 'none', letterSpacing: 0 }}>
          {shortAddress(address)}
        </span>
      </button>
      {open && (
        <div className="wallet-pop">
          <WalletPanel onDone={() => setOpen(false)} />
        </div>
      )}
    </div>
  )
}

/** Renders children only when a wallet is connected on Arbitrum Sepolia; otherwise the step needed to get there. */
export function NetworkGate({ children, compact }: { children: ReactNode; compact?: boolean }) {
  const { isConnected } = useAccount()
  const wrong = useWrongNetwork()
  const { switchChain, isPending } = useSwitchChain()

  if (!isConnected) return <ConnectButton block={!compact} />
  if (wrong)
    return (
      <div className="stack" style={{ gap: 6 }}>
        <button type="button" className="btn btn-primary" disabled={isPending} onClick={() => switchChain({ chainId: CLINOVA_CHAIN.id })}>
          Switch to Arbitrum Sepolia
        </button>
        {!compact && <span className="faint" style={{ fontSize: 13 }}>Clinova currently runs on Arbitrum Sepolia.</span>}
      </div>
    )
  return <>{children}</>
}

export function WrongNetworkBanner() {
  const wrong = useWrongNetwork()
  const { switchChain, isPending } = useSwitchChain()
  if (!wrong) return null
  return (
    <div className="container" style={{ marginTop: 16 }}>
      <div className="banner warn">
        <div>
          <strong>Clinova currently runs on Arbitrum Sepolia.</strong>
          <p>Your wallet is on another network. You can browse, but transactions are disabled until you switch.</p>
        </div>
        <button type="button" className="btn btn-primary" disabled={isPending} onClick={() => switchChain({ chainId: CLINOVA_CHAIN.id })}>
          Switch network
        </button>
      </div>
    </div>
  )
}
