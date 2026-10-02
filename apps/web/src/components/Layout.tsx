import { useState } from 'react'
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom'
import { CONTRACT_LIST, EXPLORER_URL } from '../config/contracts'
import { useIsVerifier, useProtocol, useWrongNetwork } from '../hooks/useClinova'
import { addressUrl } from '../lib/format'
import { WalletButton, WrongNetworkBanner } from './Wallet'

export function LogoMark() {
  return (
    <svg className="logo-mark" viewBox="0 0 24 24" fill="none" aria-hidden>
      <path d="M12 4v16M4 12h16" stroke="#36f4a4" strokeWidth="1.6" strokeLinecap="round" />
      <circle cx="12" cy="4" r="2" fill="#02090a" stroke="#36f4a4" strokeWidth="1.4" />
      <circle cx="12" cy="20" r="2" fill="#02090a" stroke="#36f4a4" strokeWidth="1.4" />
      <circle cx="4" cy="12" r="2" fill="#02090a" stroke="#36f4a4" strokeWidth="1.4" />
      <circle cx="20" cy="12" r="2" fill="#02090a" stroke="#36f4a4" strokeWidth="1.4" />
      <circle cx="12" cy="12" r="2.6" fill="#36f4a4" />
    </svg>
  )
}

function Nav() {
  const isVerifier = useIsVerifier()
  const wrong = useWrongNetwork()
  const [open, setOpen] = useState(false)
  const close = () => setOpen(false)
  return (
    <header className="nav">
      <div className="container nav-inner">
        <Link to="/" className="logo" onClick={close}>
          <LogoMark />
          Clinova
        </Link>
        <nav className={`nav-links ${open ? 'open' : ''}`} aria-label="Main">
          <NavLink to="/discover" onClick={close}>
            Discover
          </NavLink>
          <NavLink to="/buyer" onClick={close}>
            Healthcare businesses
          </NavLink>
          <NavLink to="/provider" onClick={close}>
            Providers
          </NavLink>
          {isVerifier && (
            <NavLink to="/verifier" onClick={close}>
              Verifier
            </NavLink>
          )}
        </nav>
        <span className="spacer" />
        <div className="nav-right">
          <span className={`net-pill ${wrong ? 'wrong' : ''}`}>Clinova Testnet · Arbitrum Sepolia</span>
          <WalletButton />
          <button type="button" className="menu-btn" aria-label="Menu" aria-expanded={open} onClick={() => setOpen(!open)}>
            ☰
          </button>
        </div>
      </div>
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
          <div className="logo" style={{ fontSize: 16, marginBottom: 12 }}>
            <LogoMark /> Clinova
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
