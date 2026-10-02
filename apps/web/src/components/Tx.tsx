import type { ReactNode } from 'react'
import type { TransactionReceipt } from 'viem'
import { useTx, type TxState } from '../hooks/useTx'
import type { ContractCall } from '../lib/contracts/calls'
import { TxLink } from './ui'
import { NetworkGate } from './Wallet'

const PHASE_TEXT: Record<TxState['phase'], string> = {
  idle: '',
  checking: 'Checking with the contract…',
  wallet: 'Waiting for wallet confirmation…',
  confirming: 'Submitted — confirming on Arbitrum…',
  confirmed: 'Confirmed onchain',
  failed: 'Failed',
}

/** Reusable status line for any write. Success is only shown once the receipt is confirmed. */
export function TxStatus({ state, onDismiss }: { state: TxState; onDismiss?: () => void }) {
  if (state.phase === 'idle') return null
  const pending = state.phase === 'checking' || state.phase === 'wallet' || state.phase === 'confirming'
  return (
    <div className="tx" role="status" aria-live="polite">
      <div className="tx-line">
        <span className="row" style={{ gap: 10 }}>
          {pending && <span className="spinner" aria-hidden />}
          {state.phase === 'confirmed' && <span className="badge ok">{PHASE_TEXT.confirmed}</span>}
          {state.phase === 'failed' && <span className="badge bad">{state.hash ? 'Failed onchain' : 'Not sent'}</span>}
          {pending && <span>{PHASE_TEXT[state.phase]}</span>}
        </span>
        <span className="row" style={{ gap: 12 }}>
          {state.hash && <TxLink hash={state.hash} />}
          {state.phase === 'failed' && onDismiss && (
            <button type="button" className="btn-small" onClick={onDismiss}>
              Dismiss
            </button>
          )}
        </span>
      </div>
      {state.error && (
        <>
          <div style={{ marginTop: 8 }}>{state.error.message}</div>
          <details className="tech">
            <summary>Technical details</summary>
            <pre>{state.error.technical}</pre>
          </details>
        </>
      )}
    </div>
  )
}

/** A button that runs one contract call through simulate → wallet → confirm, with status underneath. */
export function TxButton({
  call,
  children,
  variant = 'primary',
  disabled,
  onConfirmed,
  confirm,
  block,
}: {
  call: ContractCall | null
  children: ReactNode
  variant?: 'primary' | 'ghost' | 'danger' | 'small'
  disabled?: boolean
  onConfirmed?: (receipt: TransactionReceipt) => void
  /** Optional confirmation prompt for irreversible or consequential actions. */
  confirm?: string
  block?: boolean
}) {
  const tx = useTx()
  const cls = variant === 'small' ? 'btn-small' : `btn btn-${variant}`
  return (
    <div className="stack" style={{ gap: 10 }}>
      <NetworkGate compact>
        <button
          type="button"
          className={`${cls} ${block ? 'btn-block' : ''}`}
          disabled={disabled || !call || tx.busy}
          onClick={async () => {
            if (!call) return
            if (confirm && !window.confirm(confirm)) return
            const receipt = await tx.run(call)
              if (receipt) onConfirmed?.(receipt)
          }}
        >
          {tx.busy && <span className="spinner" aria-hidden />}
          {children}
        </button>
      </NetworkGate>
      <TxStatus state={tx} onDismiss={tx.reset} />
    </div>
  )
}

/** One numbered step in a multi-transaction flow (e.g. Approve USDC → Fund request). */
export function StepCard({
  index,
  total,
  title,
  description,
  status,
  children,
}: {
  index: number
  total: number
  title: string
  description?: ReactNode
  status: 'todo' | 'current' | 'done'
  children?: ReactNode
}) {
  return (
    <div className={`step ${status}`}>
      <div className="step-head">
        <div>
          <div className="step-num">
            Step {index} of {total}
          </div>
          <div style={{ fontSize: 18, marginTop: 2 }}>{title}</div>
        </div>
        {status === 'done' && <span className="badge ok">Done</span>}
      </div>
      {description && (
        <div className="muted" style={{ fontSize: 14, marginTop: 6 }}>
          {description}
        </div>
      )}
      {status === 'current' && children && <div style={{ marginTop: 14 }}>{children}</div>}
    </div>
  )
}
