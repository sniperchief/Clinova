import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom'
import { CONTRACT_LIST, EXPLORER_URL } from '../config/contracts'
import { useIsVerifier, useProtocol, useWrongNetwork } from '../hooks/useClinova'
import { addressUrl } from '../lib/format'
import { useAccount } from 'wagmi'
import { WalletButton, WalletPanel, WrongNetworkBanner } from './Wallet'

/** Clinova logo (flask mark + wordmark), from public/brand. */
export function Logo({ height = 26 }: { height?: number }) {
  return <img className="logo-img" src="/brand/clinova-logo-120.png" alt="Clinova" height={height} width={Math.round(height * 4.48)} />
}

const NAV_ITEMS = [
  { to: '/discover', label: 'Discover' },
  { to: '/buyer', label: 'Healthcare businesses' },
  { to: '/provider', label: 'Providers' },
]

function Nav() {
  const isVerifier = useIsVerifier()
  const wrong = useWrongNetwork()
  const { pathname } = useLocation()
  const { isConnected } = useAccount()
  const [open, setOpen] = useState(false)
  const close = () => setOpen(false)
  const items = isVerifier ? [...NAV_ITEMS, { to: '/verifier', label: 'Verifier' }] : NAV_ITEMS

  // Close the menu on navigation (derived-state pattern).
  const [lastPath, setLastPath] = useState(pathname)
  if (pathname !== lastPath) {
    setLastPath(pathname)
    setOpen(false)
  }

  // While the full-screen menu is open: lock page scroll and close on Escape.
  useEffect(() => {
    if (!open) return
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false)
    document.addEventListener('keydown', onKey)
    return () => {
      document.body.style.overflow = prev
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <header className="nav">
      <div className="container nav-inner">
        <Link to="/" className="logo" onClick={close} aria-label="Clinova home">
          <Logo />
        </Link>
        <nav className="nav-links" aria-label="Main">
          {items.map((i) => (
            <NavLink key={i.to} to={i.to}>
              {i.label}
            </NavLink>
          ))}
        </nav>
        <span className="spacer" />
        <div className="nav-right">
          <div className="nav-wallet">
            <WalletButton />
          </div>
          <button
            type="button"
            className="menu-btn"
            aria-label="Open menu"
            aria-expanded={open}
            aria-controls="mobile-menu"
            onClick={() => setOpen(true)}
          >
            {isConnected && <span className={`menu-dot ${wrong ? 'wrong' : ''}`} aria-hidden />}☰
          </button>
        </div>
      </div>

      {open &&
        createPortal(
        <div id="mobile-menu" className="mobile-menu" role="dialog" aria-modal="true" aria-label="Menu">
          <div className="mobile-menu-top">
            <Link to="/" className="logo" onClick={close} aria-label="Clinova home">
              <Logo />
            </Link>
            <button type="button" className="menu-btn menu-close" aria-label="Close menu" onClick={close}>
              ✕
            </button>
          </div>
          <nav className="mobile-menu-links" aria-label="Main">
            {items.map((i) => (
              <NavLink key={i.to} to={i.to} onClick={close}>
                {i.label}
                <span aria-hidden>→</span>
              </NavLink>
            ))}
          </nav>
          <section className="mobile-menu-wallet" aria-label="Wallet">
            <div className="eyebrow">{isConnected ? 'Wallet' : 'Connect a wallet'}</div>
            <WalletPanel onDone={close} />
          </section>
        </div>,
          document.body,
        )}
    </header>
  )
}

function PausedBanner() {
  const p = useProtocol().data
  if (!p?.marketplacePaused && !p?.registryPaused) return null
  return (
    <div className="container" style={{ marginTop: 16 }}>
      <div className="banner warn" role="alert">
        <div>
          <strong>Clinova is temporarily paused.</strong>
          <p>
            {p.marketplacePaused && 'New requests and job acceptances are currently unavailable. '}
            {p.registryPaused && 'New provider registrations and stake deposits are currently unavailable. '}
            Existing funds remain withdrawable and refundable, and in-progress requests can continue, according to
            protocol rules.
          </p>
        </div>
      </div>
    </div>
  )
}

function Footer() {
  return (
    <footer className="footer">
      <div className="container cols">
        <div>
          <div className="logo" style={{ marginBottom: 14 }}>
            <Logo height={22} />
          </div>
          <p style={{ maxWidth: 460, margin: 0 }}>
            Testnet software on Arbitrum Sepolia; the contracts are not externally audited. Clinova coordinates access to
            diagnostic capacity and payment. It does not provide medical advice, store patient records, or guarantee
            provider quality or availability. Provider names marked “demo” are synthetic.
          </p>
        </div>
        <div>
          <h5>Contracts</h5>
          {CONTRACT_LIST.map((c) => (
            <a key={c.address} href={`${addressUrl(c.address)}#code`} target="_blank" rel="noreferrer">
              {c.name} ↗
            </a>
          ))}
        </div>
        <div>
          <h5>Network</h5>
          <a href={EXPLORER_URL} target="_blank" rel="noreferrer">
            Arbiscan (Sepolia) ↗
          </a>
          <a href="https://faucet.circle.com" target="_blank" rel="noreferrer">
            Testnet USDC faucet ↗
          </a>
          <a href="https://www.alchemy.com/faucets/arbitrum-sepolia" target="_blank" rel="noreferrer">
            Testnet ETH faucet ↗
          </a>
        </div>
      </div>
    </footer>
  )
}

export function Layout() {
  const { pathname } = useLocation()
  return (
    <>
      <Nav />
      <WrongNetworkBanner />
      <PausedBanner />
      <main key={pathname}>
        <Outlet />
      </main>
      <Footer />
    </>
  )
}
