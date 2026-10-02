import type { Address, Hex } from 'viem'
import { describe, expect, it } from 'vitest'
import { availableActions, outcomeSummary, type ActionContext } from '../contracts/requestActions'
import { EscrowState, ProofStatus, Status, type RequestRecord } from '../contracts/types'
import { ZERO_ADDRESS } from '../format'

const BUYER: Address = '0x00000000000000000000000000000000000000b1'
const PROVIDER: Address = '0x00000000000000000000000000000000000000a1'
const VERIFIER: Address = '0x00000000000000000000000000000000000000c1'
const OTHER: Address = '0x00000000000000000000000000000000000000d1'
const ZERO32: Hex = `0x${'00'.repeat(32)}`
const T = 1_000_000n

function rec(status: Status, over: Partial<RequestRecord['request']> = {}, proof: ProofStatus = ProofStatus.NONE): RequestRecord {
  const accepted = status !== Status.OPEN
  return {
    id: 1n,
    outcomeRecorded: false,
    request: {
      buyer: BUYER,
      createdAt: T - 100n,
      status,
      disputedFrom: Status.NONE,
      provider: accepted ? PROVIDER : ZERO_ADDRESS,
      acceptDeadline: T + 3600n,
      serviceType: `0x${'ab'.repeat(32)}`,
      locationHash: `0x${'cd'.repeat(32)}`,
      price: 25_000_000n,
      serviceDeadline: T + 86400n,
      reviewPeriod: 604800,
      disputePeriod: 1209600,
      reviewDeadline: status === Status.COMPLETED ? T + 604800n : 0n,
      disputeDeadline: status === Status.DISPUTED ? T + 1209600n : 0n,
      ...over,
    },
    deposit: { payer: BUYER, amount: 25_000_000n, state: EscrowState.FUNDED, payee: accepted ? PROVIDER : ZERO_ADDRESS },
    proof: {
      provider: PROVIDER,
      submittedAt: 0n,
      status: proof,
      reviewer: ZERO_ADDRESS,
      reviewedAt: 0n,
      evidenceCommitment: ZERO32,
      proofHash: ZERO32,
    },
  }
}

const ctx = (account: Address, over: Partial<ActionContext> = {}): ActionContext => ({
  account,
  now: T,
  isVerifier: account === VERIFIER,
  marketplacePaused: false,
  isEligible: () => account === PROVIDER,
  ...over,
})
const ids = (r: RequestRecord, c: ActionContext) => availableActions(r, c).map((a) => (a.blockedReason ? `${a.id}!` : a.id))

describe('available actions mirror the contract transition table', () => {
  it('OPEN', () => {
    expect(ids(rec(Status.OPEN), ctx(BUYER))).toEqual(['cancel'])
    expect(ids(rec(Status.OPEN), ctx(PROVIDER))).toEqual(['accept'])
    expect(ids(rec(Status.OPEN), ctx(OTHER))).toEqual(['accept!']) // not eligible: shown disabled with a reason
    expect(ids(rec(Status.OPEN), ctx(PROVIDER, { marketplacePaused: true }))).toEqual(['accept!'])
    expect(ids(rec(Status.OPEN, { provider: OTHER }), ctx(PROVIDER))).toEqual([]) // directed to someone else
    expect(ids(rec(Status.OPEN), ctx(OTHER, { now: T + 3601n }))).toEqual(['expireOpen'])
    // Cancelling (a refund) stays available while paused.
    expect(ids(rec(Status.OPEN), ctx(BUYER, { marketplacePaused: true }))).toEqual(['cancel'])
  })

  it('ACCEPTED / IN_SERVICE', () => {
    expect(ids(rec(Status.ACCEPTED), ctx(PROVIDER))).toEqual(['start', 'dispute'])
    expect(ids(rec(Status.IN_SERVICE), ctx(PROVIDER))).toEqual(['submitProof', 'dispute'])
    expect(ids(rec(Status.IN_SERVICE), ctx(BUYER))).toEqual(['dispute'])
    expect(ids(rec(Status.IN_SERVICE), ctx(VERIFIER))).toEqual([])
    expect(ids(rec(Status.IN_SERVICE), ctx(BUYER, { now: T + 86401n }))).toEqual(['expireAccepted'])
  })

  it('COMPLETED', () => {
    const r = rec(Status.COMPLETED, {}, ProofStatus.SUBMITTED)
    expect(ids(r, ctx(BUYER))).toEqual(['confirm', 'dispute'])
    expect(ids(r, ctx(VERIFIER))).toEqual(['approveProof', 'rejectProof'])
    expect(ids(r, ctx(PROVIDER))).toEqual([])
    // A verifier who is the buyer may only act as the buyer (ConflictOfInterest onchain).
    expect(ids(r, ctx(BUYER, { isVerifier: true }))).toEqual(['confirm', 'dispute'])
    expect(ids(r, ctx(OTHER, { now: T + 604801n }))).toEqual(['closeUnreviewed'])
  })

  it('DISPUTED', () => {
    const r = rec(Status.DISPUTED, { disputedFrom: Status.IN_SERVICE })
    expect(ids(r, ctx(PROVIDER))).toEqual(['submitProof']) // dispute evidence (T12b)
    expect(ids(r, ctx(VERIFIER))).toEqual(['resolveDispute'])
    expect(ids(r, ctx(OTHER, { now: T + 1209601n }))).toEqual(['disputeTimeout'])
    const fromCompleted = rec(Status.DISPUTED, { disputedFrom: Status.COMPLETED }, ProofStatus.SUBMITTED)
    expect(ids(fromCompleted, ctx(PROVIDER))).toEqual([])
  })

  it('terminal states offer nothing (e.g. no “Confirm completion” once settled)', () => {
    for (const s of [Status.SETTLED, Status.CANCELLED, Status.EXPIRED, Status.REFUNDED])
      for (const a of [BUYER, PROVIDER, VERIFIER, OTHER]) expect(ids(rec(s), ctx(a))).toEqual([])
  })

  it('describes outcomes from onchain state', () => {
    expect(outcomeSummary(rec(Status.SETTLED, {}, ProofStatus.BUYER_ACCEPTED))).toBe('Settlement complete — buyer confirmed')
    expect(outcomeSummary(rec(Status.SETTLED, { disputedFrom: Status.COMPLETED }, ProofStatus.APPROVED))).toBe(
      'Resolved — provider paid',
    )
    expect(outcomeSummary(rec(Status.IN_SERVICE))).toBeNull()
  })
})
