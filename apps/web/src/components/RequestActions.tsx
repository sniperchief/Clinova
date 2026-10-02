import { useState } from 'react'
import { CLINOVA_ADDRESSES } from '../config/contracts'
import { useAccountState, useNow, useProtocol, useSelfEligibility } from '../hooks/useClinova'
import { calls } from '../lib/contracts/calls'
import { availableActions, canResolveForProvider, type ActionId } from '../lib/contracts/requestActions'
import { Resolution, type RequestRecord } from '../lib/contracts/types'
import {
  buildEvidencePackage,
  buildReason,
  checkEvidencePackage,
  hashFile,
  randomSalt,
  syntheticEvidenceFile,
  type EvidencePackage,
} from '../lib/commitments'
import { downloadJson, loadEvidence, saveEvidence, saveReason } from '../lib/localRecords'
import { formatDateTime, usdc } from '../lib/format'
import { TxButton } from './Tx'
import { Hash } from './ui'
import { useAccount } from 'wagmi'

const SIMPLE: Partial<Record<ActionId, { label: string; help: string; variant?: 'primary' | 'ghost' | 'danger'; confirm?: string }>> = {
  cancel: {
    label: 'Cancel request',
    help: 'No provider has accepted yet. Cancelling credits the full payment back to you.',
    variant: 'ghost',
    confirm: 'Cancel this request? The payment will be credited back to you for withdrawal.',
  },
  expireOpen: {
    label: 'Close expired request',
    help: 'No provider accepted before the deadline. Anyone can close it; the payment goes back to the buyer.',
    variant: 'ghost',
  },
  accept: { label: 'Accept job', help: 'Commit to performing this service before the service deadline.' },
  start: { label: 'Start service', help: 'Mark that the service has begun (for example, the sample was collected).' },
  confirm: {
    label: 'Confirm completion',
    help: 'Releases the escrowed payment to the provider. This cannot be undone.',
    confirm: 'Confirm the service was completed and release payment to the provider?',
  },
  expireAccepted: {
    label: 'Close — provider missed deadline',
    help: 'The service deadline passed without proof. Closing refunds the buyer and records a failed job for the provider.',
    variant: 'danger',
  },
  closeUnreviewed: {
    label: 'Close unreviewed',
    help: 'Nobody reviewed the proof within the review window. Anyone can close it: the buyer is refunded, with no fault recorded.',
    variant: 'ghost',
  },
  approveProof: {
    label: 'Approve proof',
    help: 'You have checked the evidence. Approval settles the payment to the provider.',
    confirm: 'Approve this proof and release payment to the provider?',
  },
  disputeTimeout: {
    label: 'Close timed-out dispute',
    help: 'No verifier resolved the dispute in time. Anyone can close it; the buyer is refunded with no fault recorded.',
    variant: 'ghost',
  },
}

const callFor = (id: ActionId, requestId: bigint) => {
  switch (id) {
    case 'cancel':
      return calls.cancelRequest(requestId)
    case 'expireOpen':
    case 'expireAccepted':
      return calls.expireRequest(requestId)
    case 'accept':
      return calls.acceptRequest(requestId)
    case 'start':
      return calls.startService(requestId)
    case 'confirm':
      return calls.confirmCompletion(requestId)
    case 'closeUnreviewed':
      return calls.closeUnreviewed(requestId)
    case 'approveProof':
      return calls.approveProof(requestId)
    case 'disputeTimeout':
      return calls.resolveDisputeByTimeout(requestId)
    default:
      return null
  }
}

export function RequestActions({ rec }: { rec: RequestRecord }) {
  const { address } = useAccount()
  const account = useAccountState().data
  const protocol = useProtocol().data
  const isEligible = useSelfEligibility()
  const now = useNow()
  const actions = availableActions(rec, {
    account: address,
    now,
    isVerifier: !!account?.isMarketplaceVerifier,
    marketplacePaused: !!protocol?.marketplacePaused,
    isEligible,
  })

  if (!address) return <p className="muted" style={{ margin: 0 }}>Connect a wallet to see the actions available to you.</p>
  if (actions.length === 0) return <p className="muted" style={{ margin: 0 }}>There is nothing for your wallet to do on this request right now.</p>

  return (
    <div className="stack" style={{ gap: 20 }}>
      {actions.map((a) => {
        const simple = SIMPLE[a.id]
        if (simple)
          return (
            <div key={a.id} className="stack" style={{ gap: 8 }}>
              <p className="muted" style={{ margin: 0, fontSize: 14 }}>
                {a.blockedReason ?? simple.help}
              </p>
              <TxButton call={callFor(a.id, rec.id)} variant={simple.variant} disabled={!!a.blockedReason} confirm={simple.confirm} block>
                {simple.label}
              </TxButton>
            </div>
          )
        if (a.id === 'submitProof') return <SubmitProof key={a.id} rec={rec} />
        if (a.id === 'dispute') return <ReasonForm key={a.id} rec={rec} kind="dispute" />
        if (a.id === 'rejectProof') return <ReasonForm key={a.id} rec={rec} kind="reject" />
        if (a.id === 'resolveDispute') return <ResolveDispute key={a.id} rec={rec} />
        return null
      })}
    </div>
  )
}

// -------------------------------------------------------------------------------------------------------------------

function SubmitProof({ rec }: { rec: RequestRecord }) {
  const [pkg, setPkg] = useState<EvidencePackage | null>(null)
  const [fileNote, setFileNote] = useState('')
  const [error, setError] = useState('')

  const build = async (file: Blob, synthetic: boolean) => {
    setError('')
    try {
      const evidenceFileHash = await hashFile(file)
      const p = buildEvidencePackage(
        {
          chainId: CLINOVA_ADDRESSES.chainId,
          proofOfService: CLINOVA_ADDRESSES.proofOfService,
          requestId: rec.id.toString(),
          provider: rec.request.provider,
        },
        evidenceFileHash,
        synthetic,
      )
      saveEvidence(rec.id, p)
      setPkg(p)
    } catch (e) {
      setError(String(e))
    }
  }

  return (
    <div className="stack" style={{ gap: 12 }}>
      <div>
        <strong>Submit proof of service</strong>
        <p className="muted" style={{ margin: '4px 0 0', fontSize: 14 }}>
          Your evidence file is hashed in this browser and <strong>never uploaded</strong>. Only a salted 32-byte
          commitment goes onchain. Keep the evidence package — the verifier needs it to check your proof.
        </p>
      </div>
      <div className="row">
        <label className="btn-small" style={{ cursor: 'pointer' }}>
          Choose evidence file
          <input
            type="file"
            hidden
            onChange={(e) => {
              const f = e.target.files?.[0]
              if (f) {
                setFileNote('Evidence file hashed locally')
                void build(f, false)
              }
            }}
          />
        </label>
        <button
          type="button"
          className="btn-small"
          onClick={() => {
            setFileNote('Synthetic demo evidence (no patient data)')
            void build(syntheticEvidenceFile(rec.id), true)
          }}
        >
          Use synthetic demo evidence
        </button>
      </div>
      <p className="faint" style={{ margin: 0, fontSize: 12 }}>
        Never put patient names, contact details or results into anything submitted to Clinova.
      </p>
      {error && <span className="error">{error}</span>}
      {pkg && (
        <div className="tx stack" style={{ gap: 6 }}>
          <span className="faint" style={{ fontSize: 13 }}>{fileNote}</span>
          <span style={{ fontSize: 13 }}>
            Commitment <Hash value={pkg.evidenceCommitment} />
          </span>
          <button
            type="button"
            className="btn-small"
            style={{ alignSelf: 'flex-start' }}
            onClick={() => downloadJson(`clinova-evidence-request-${rec.id}.json`, pkg)}
          >
            Download evidence package
          </button>
        </div>
      )}
      <TxButton call={pkg ? calls.submitProof(rec.id, pkg.evidenceCommitment) : null} block>
        Submit proof
      </TxButton>
    </div>
  )
}

// -------------------------------------------------------------------------------------------------------------------

const CATEGORIES = {
  dispute: ['Service not delivered', 'Service incomplete', 'Sample handling issue', 'Wrong service performed', 'Other'],
  reject: ['Evidence does not match the request', 'Manifest names another request', 'Evidence incomplete', 'Other'],
}

function ReasonForm({ rec, kind }: { rec: RequestRecord; kind: 'dispute' | 'reject' }) {
  const [category, setCategory] = useState(CATEGORIES[kind][0])
  const [note, setNote] = useState('')
  // Salted so the onchain hash cannot be dictionary-reversed; one salt per form keeps the call stable.
  const [salt] = useState(randomSalt)
  const reason = buildReason(rec.id, category, note, salt)
  const isDispute = kind === 'dispute'

  return (
    <div className="stack" style={{ gap: 12 }}>
      <div>
        <strong>{isDispute ? 'Dispute this service' : 'Reject proof'}</strong>
        <p className="muted" style={{ margin: '4px 0 0', fontSize: 14 }}>
          {isDispute
            ? 'Payment stays in escrow and a verifier decides the outcome. If no verifier acts in time, you are refunded.'
            : 'Rejection is final for this proof: it can never lead to payment. The request moves to dispute for resolution.'}
        </p>
      </div>
      <div className="field">
        <label htmlFor={`reason-${kind}`}>Reason</label>
        <select id={`reason-${kind}`} className="input" value={category} onChange={(e) => setCategory(e.target.value)}>
          {CATEGORIES[kind].map((c) => (
            <option key={c}>{c}</option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={`note-${kind}`}>Note (optional, kept offchain)</label>
        <textarea
          id={`note-${kind}`}
          className="input"
          rows={2}
          value={note}
          maxLength={280}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Operational details only"
        />
        <span className="help">
          Do not include patient names, contact details or clinical findings. Only a salted hash of this reason is
          recorded onchain.
        </span>
      </div>
      <TxButton
        call={isDispute ? calls.openDispute(rec.id, reason.reasonHash) : calls.rejectProof(rec.id, reason.reasonHash)}
        variant="danger"
        block
        onConfirmed={() => saveReason(reason)}
        confirm={isDispute ? undefined : 'Reject this proof? This is final for this proof.'}
      >
        {isDispute ? 'Submit dispute' : 'Reject proof'}
      </TxButton>
    </div>
  )
}

// -------------------------------------------------------------------------------------------------------------------

function ResolveDispute({ rec }: { rec: RequestRecord }) {
  const providerPossible = canResolveForProvider(rec)
  const [choice, setChoice] = useState<Resolution>(providerPossible ? Resolution.PROVIDER_WINS : Resolution.REFUND_PROVIDER_FAULT)
  const options: { value: Resolution; title: string; help: string; disabled?: boolean }[] = [
    {
      value: Resolution.PROVIDER_WINS,
      title: 'Pay the provider',
      help: providerPossible
        ? `Release ${usdc(rec.request.price)} to the provider. Counts as a successful job.`
        : 'Not possible: there is no proof under review (none submitted, or already rejected).',
      disabled: !providerPossible,
    },
    {
      value: Resolution.REFUND_PROVIDER_FAULT,
      title: 'Refund the buyer — provider at fault',
      help: 'Refund the buyer and record a failed job for the provider.',
    },
    {
      value: Resolution.REFUND_NO_FAULT,
      title: 'Refund the buyer — no fault',
      help: 'Refund the buyer without recording fault (e.g. a cancelled appointment).',
    },
  ]
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div>
        <strong>Resolve dispute</strong>
        <p className="muted" style={{ margin: '4px 0 0', fontSize: 14 }}>
          Decision deadline {formatDateTime(rec.request.disputeDeadline)}. After that, anyone can close it as a no-fault refund.
        </p>
      </div>
      {options.map((o) => (
        <label
          key={o.value}
          className="step"
          style={{ cursor: o.disabled ? 'not-allowed' : 'pointer', opacity: o.disabled ? 0.5 : 1, borderColor: choice === o.value ? 'var(--mint)' : undefined }}
        >
          <input
            type="radio"
            name={`resolve-${rec.id}`}
            checked={choice === o.value}
            disabled={o.disabled}
            onChange={() => setChoice(o.value)}
            style={{ marginRight: 10 }}
          />
          {o.title}
          <div className="faint" style={{ fontSize: 13, marginTop: 4 }}>
            {o.help}
          </div>
        </label>
      ))}
      <TxButton call={calls.resolveDispute(rec.id, choice)} block confirm="Submit this resolution? It is final.">
        Resolve dispute
      </TxButton>
    </div>
  )
}

// -------------------------------------------------------------------------------------------------------------------

/** Verifier aid: check an evidence package against the onchain commitment and the request (spec §5, R5-3). */
export function EvidenceCheck({ rec }: { rec: RequestRecord }) {
  const [pkg, setPkg] = useState<EvidencePackage | null>(() => loadEvidence(rec.id))
  const [parseError, setParseError] = useState('')
  const result = pkg
    ? checkEvidencePackage(
        pkg,
        {
          chainId: CLINOVA_ADDRESSES.chainId,
          proofOfService: CLINOVA_ADDRESSES.proofOfService,
          requestId: rec.id.toString(),
          provider: rec.proof.provider,
        },
        rec.proof.evidenceCommitment,
      )
    : null

  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="spread">
        <strong>Evidence package check</strong>
        <label className="btn-small" style={{ cursor: 'pointer' }}>
          Load package file
          <input
            type="file"
            accept="application/json"
            hidden
            onChange={async (e) => {
              const f = e.target.files?.[0]
              if (!f) return
              try {
                setPkg(JSON.parse(await f.text()) as EvidencePackage)
                setParseError('')
              } catch {
                setParseError('That file is not a Clinova evidence package.')
              }
            }}
          />
        </label>
      </div>
      {parseError && <span className="error">{parseError}</span>}
      {!pkg ? (
        <p className="faint" style={{ margin: 0, fontSize: 13 }}>
          Load the evidence package the provider shared through the verification channel to check it against the onchain
          commitment.
        </p>
      ) : (
        <ul style={{ margin: 0, paddingLeft: 0, listStyle: 'none', fontSize: 14 }} className="stack">
          <li className={`badge ${result!.commitmentMatches ? 'ok' : 'bad'}`}>
            {result!.commitmentMatches ? 'Commitment matches the onchain proof' : 'Commitment does NOT match'}
          </li>
          <li className={`badge ${result!.manifestMatches ? 'ok' : 'bad'}`}>
            {result!.manifestMatches ? 'Manifest names this chain, contract, request and provider' : 'Manifest does NOT match this request'}
          </li>
          {pkg.bundle.synthetic && <li className="badge warn">Synthetic demo evidence</li>}
          {result!.problems.map((p) => (
            <li key={p} className="faint" style={{ fontSize: 13 }}>
              {p}
            </li>
          ))}
        </ul>
      )}
      <p className="faint" style={{ margin: 0, fontSize: 12 }}>
        This check proves the package is the one committed onchain. Whether the evidence shows the service was performed
        remains the verifier’s judgement.
      </p>
    </div>
  )
}
