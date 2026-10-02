import type { ReactNode } from 'react'
import { getAddress, type Hex } from 'viem'
import { DEMO_DIRECTORY, regionByHash, serviceByHash } from '../config/catalog'
import { addressUrl, formatUsdc, shortAddress, shortHash, txUrl } from '../lib/format'

export function ExtLink({ href, children, className = 'link' }: { href: string; children: ReactNode; className?: string }) {
  return (
    <a href={href} target="_blank" rel="noreferrer" className={`${className} ext`}>
      {children}
    </a>
  )
}

export const TxLink = ({ hash, children }: { hash: Hex; children?: ReactNode }) => (
  <ExtLink href={txUrl(hash)}>{children ?? 'View on Arbiscan'}</ExtLink>
)

/** An address, with its synthetic demo label if one exists, linked to Arbiscan. */
export function Addr({ address, label }: { address: string; label?: string | null }) {
  const demo = DEMO_DIRECTORY[getAddress(address)]
  const name = label ?? demo?.label
  return (
    <span className="row" style={{ gap: 6, display: 'inline-flex' }}>
      {name && <span>{name}</span>}
      <a href={addressUrl(address)} target="_blank" rel="noreferrer" className="link mono" title={address}>
        {shortAddress(address)}
      </a>
      {demo && !label && (
        <span className="chip demo" title={demo.note}>
          demo
        </span>
      )}
    </span>
  )
}

export const Hash = ({ value }: { value: string }) => (
  <span className="mono" title={value}>
    {shortHash(value)}
  </span>
)

export function Usdc({ amount, unit = true }: { amount: bigint; unit?: boolean }) {
  return (
    <span style={{ fontVariantNumeric: 'tabular-nums' }}>
      {formatUsdc(amount)}
      {unit && <span className="faint"> USDC</span>}
    </span>
  )
}

export function ServiceName({ hash, short = false }: { hash: Hex; short?: boolean }) {
  const s = serviceByHash(hash)
  if (!s)
    return (
      <span title={`Uncatalogued service code ${hash}`}>
        Service <span className="mono">{shortHash(hash)}</span>
      </span>
    )
  return <span title={s.code}>{short ? s.short : s.name}</span>
}

export function RegionName({ hash }: { hash: Hex }) {
  const r = regionByHash(hash)
  if (!r)
    return (
      <span className="faint" title={`Region commitment ${hash} is not in the public region catalog`}>
        Unlisted region
      </span>
    )
  return <span title={r.code}>{r.name}</span>
}

export function Stat({ label, value, hint, unit }: { label: string; value: ReactNode; hint?: ReactNode; unit?: string }) {
  return (
    <div className="card stat">
      <div className="label">{label}</div>
      <div className="value">
        {value}
        {unit && <small>{unit}</small>}
      </div>
      {hint && <div className="hint">{hint}</div>}
    </div>
  )
}

export const Badge = ({ tone, children }: { tone?: 'ok' | 'progress' | 'warn' | 'bad'; children: ReactNode }) => (
  <span className={`badge ${tone ?? ''}`}>{children}</span>
)

export const Empty = ({ children }: { children: ReactNode }) => <div className="empty">{children}</div>

export const Skeleton = ({ width = '100%', height = 18 }: { width?: number | string; height?: number }) => (
  <div className="skeleton" style={{ width, height }} />
)

export function LoadError({ error }: { error: unknown }) {
  return (
    <div className="banner bad">
      <div>
        <strong>Could not read from Arbitrum Sepolia.</strong>
        <p>The RPC endpoint may be rate-limiting. The page retries automatically.</p>
        <details className="tech">
          <summary>Technical details</summary>
          <pre>{String(error instanceof Error ? error.message : error)}</pre>
        </details>
      </div>
    </div>
  )
}
