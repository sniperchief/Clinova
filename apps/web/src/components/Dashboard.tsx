import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import type { RequestRecord } from '../lib/contracts/types'
import { formatRelative, isZeroAddress, shortAddress } from '../lib/format'
import { jobState, upcomingDeadline, type Perspective } from '../lib/jobs'
import { RegionName, ServiceName, Skeleton, Usdc } from './ui'

/** Page header for a dashboard: identity tile, title, facts row, and actions. */
export function DashHeader({
  eyebrow,
  title,
  tile,
  meta,
  actions,
}: {
  eyebrow: string
  title: ReactNode
  tile: ReactNode
  meta?: ReactNode
  actions?: ReactNode
}) {
  return (
    <header className="dash-head">
      <div className="dash-tile" aria-hidden>
        {tile}
      </div>
      <div className="dash-title">
        <span className="eyebrow">{eyebrow}</span>
        <h1>{title}</h1>
        {meta && <div className="dash-meta">{meta}</div>}
      </div>
      {actions && <div className="dash-actions">{actions}</div>}
    </header>
  )
}

export interface Metric {
  label: string
  value: ReactNode
  unit?: string
  hint?: ReactNode
  highlight?: boolean
}

/** One bordered strip of key figures divided by hairlines. */
export function MetricStrip({ items, loading }: { items: Metric[]; loading?: boolean }) {
  return (
    <section className="metric-strip" aria-label="Key figures">
      {items.map((m) => (
        <div key={m.label} className={m.highlight ? 'is-highlight' : undefined}>
          <span className="metric-label">{m.label}</span>
          <span className="metric-value">
            {loading ? <Skeleton width={56} height={28} /> : m.value}
            {m.unit && !loading && <small>{m.unit}</small>}
          </span>
          {m.hint && <span className="metric-hint">{m.hint}</span>}
        </div>
      ))}
    </section>
  )
}

/** A titled panel. */
export function Panel({
  title,
  subtitle,
  aside,
  children,
  flush,
}: {
  title: ReactNode
  subtitle?: ReactNode
  aside?: ReactNode
  children: ReactNode
  flush?: boolean
}) {
  return (
    <section className="panel">
      <header className="panel-head">
        <div>
          <h2>{title}</h2>
          {subtitle && <p>{subtitle}</p>}
        </div>
        {aside}
      </header>
      <div className={flush ? 'panel-body flush' : 'panel-body'}>{children}</div>
    </section>
  )
}

export interface TabDef<T extends string> {
  id: T
  label: string
  count?: number
  attention?: boolean
}

export function Tabs<T extends string>({ tabs, value, onChange }: { tabs: TabDef<T>[]; value: T; onChange: (id: T) => void }) {
  return (
    <div className="tabs" role="tablist">
      {tabs.map((t) => (
        <button
          key={t.id}
          type="button"
          role="tab"
          aria-selected={value === t.id}
          className={t.attention && t.count ? 'has-attention' : undefined}
          onClick={() => onChange(t.id)}
        >
          {t.label}
          {t.count !== undefined && <span className="tab-count">{t.count}</span>}
        </button>
      ))}
    </div>
  )
}

/** Request rows with what the party needs to do next. Each row links to the request page. */
export function JobList({
  jobs,
  perspective,
  now,
  empty,
}: {
  jobs: RequestRecord[]
  perspective: Perspective
  now: bigint
  empty: ReactNode
}) {
  if (jobs.length === 0) return <div className="job-empty">{empty}</div>
  return (
    <ul className="jobs">
      {jobs.map((rec) => {
        const state = jobState(rec, perspective, now)
        const deadline = upcomingDeadline(rec)
        const other = perspective === 'buyer' ? rec.request.provider : rec.request.buyer
        return (
          <li key={rec.id.toString()}>
            <Link to={`/requests/${rec.id}`} className={`job ${state.actionNeeded ? 'job-action' : ''}`}>
              <div className="job-main">
                <div className="job-title">
                  <ServiceName hash={rec.request.serviceType} />
                  <span className="job-id">#{rec.id.toString()}</span>
                </div>
                <div className="job-sub">
                  {perspective === 'buyer' ? 'Provider ' : 'Buyer '}
                  <span className="mono">
                    {isZeroAddress(other) ? 'any eligible' : shortAddress(other)}
                  </span>
                  <span className="dot-sep" aria-hidden>
                    ·
                  </span>
                  <RegionName hash={rec.request.locationHash} />
                </div>
              </div>
              <div className="job-amount">
                <Usdc amount={rec.request.price} />
              </div>
              <div className="job-state">
                <span className={`pill pill-${state.tone}`}>{state.label}</span>
                {deadline && (
                  <span className="job-deadline">
                    {deadline.label} {formatRelative(deadline.at, now)}
                  </span>
                )}
              </div>
              <div className="job-next">
                {state.actionNeeded ? <span className="job-cta">{state.next} →</span> : <span>{state.next}</span>}
              </div>
            </Link>
          </li>
        )
      })}
    </ul>
  )
}

export interface SetupStep {
  title: string
  done: boolean
}

/** Horizontal progress tracker; the body explains the current step. */
export function SetupTracker({ steps, children }: { steps: SetupStep[]; children?: ReactNode }) {
  const current = steps.findIndex((s) => !s.done)
  return (
    <section className="setup">
      <ol className="setup-steps">
        {steps.map((s, i) => (
          <li key={s.title} className={s.done ? 'done' : i === current ? 'current' : undefined}>
            <span className="setup-dot">{s.done ? '✓' : i + 1}</span>
            <span className="setup-title">{s.title}</span>
          </li>
        ))}
      </ol>
      {children && <div className="setup-body">{children}</div>}
    </section>
  )
}

/** Numbered explainer panel for first-time visitors. */
export function HowItWorks({ title, steps }: { title: string; steps: [string, string][] }) {
  return (
    <Panel title={title}>
      <ol className="how-list">
        {steps.map(([t, d], i) => (
          <li key={t}>
            <span className="how-num">{i + 1}</span>
            <div>
              <strong>{t}</strong>
              <p>{d}</p>
            </div>
          </li>
        ))}
      </ol>
    </Panel>
  )
}
