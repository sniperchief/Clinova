import type { Hex } from 'viem'
import { describe, expect, it } from 'vitest'
import { ProofStatus, Status } from '../contracts/types'
import { ZERO_ADDRESS } from '../format'
import { jobState } from '../jobs'

const T = 1_000_000n
const ZERO32: Hex = `0x${'00'.repeat(32)}`

function rec(status: Status, over: { disputedFrom?: Status; proof?: ProofStatus; acceptDeadline?: bigint; serviceDeadline?: bigint } = {}) {
  return {
    request: {
      buyer: ZERO_ADDRESS,
      createdAt: 0n,
      status,
      disputedFrom: over.disputedFrom ?? Status.NONE,
      provider: ZERO_ADDRESS,
      acceptDeadline: over.acceptDeadline ?? T + 3600n,
      serviceType: ZERO32,
      locationHash: ZERO32,
      price: 5_000_000n,
      serviceDeadline: over.serviceDeadline ?? T + 86400n,
      reviewPeriod: 604800,
      disputePeriod: 1209600,
      reviewDeadline: T + 604800n,
      disputeDeadline: T + 1209600n,
    },
    proof: {
      provider: ZERO_ADDRESS,
      submittedAt: 0n,
      status: over.proof ?? ProofStatus.NONE,
      reviewer: ZERO_ADDRESS,
      reviewedAt: 0n,
      evidenceCommitment: ZERO32,
      proofHash: ZERO32,
    },
  }
}

const needs = (r: ReturnType<typeof rec>, who: 'buyer' | 'provider', now = T) => jobState(r, who, now).actionNeeded

describe('jobState: who needs to act next', () => {
  it('provider acts while the job is theirs to move forward', () => {
    expect(needs(rec(Status.OPEN), 'provider')).toBe(true)
    expect(needs(rec(Status.ACCEPTED), 'provider')).toBe(true)
    expect(needs(rec(Status.IN_SERVICE), 'provider')).toBe(true)
    expect(needs(rec(Status.COMPLETED, { proof: ProofStatus.SUBMITTED }), 'provider')).toBe(false)
  })

  it('buyer acts on a submitted proof, a closed window or a missed deadline', () => {
    expect(needs(rec(Status.OPEN), 'buyer')).toBe(false)
    expect(needs(rec(Status.COMPLETED, { proof: ProofStatus.SUBMITTED }), 'buyer')).toBe(true)
    expect(needs(rec(Status.OPEN), 'buyer', T + 3601n)).toBe(true) // reclaim after acceptance window
    expect(needs(rec(Status.IN_SERVICE), 'buyer', T + 86401n)).toBe(true) // provider missed deadline
    expect(needs(rec(Status.IN_SERVICE), 'provider', T + 86401n)).toBe(false)
  })

  it('disputes: only a provider who can still add evidence has an action', () => {
    expect(needs(rec(Status.DISPUTED, { disputedFrom: Status.IN_SERVICE }), 'provider')).toBe(true)
    expect(needs(rec(Status.DISPUTED, { disputedFrom: Status.COMPLETED, proof: ProofStatus.SUBMITTED }), 'provider')).toBe(false)
    expect(needs(rec(Status.DISPUTED, { disputedFrom: Status.IN_SERVICE }), 'buyer')).toBe(false)
  })

  it('finished requests never need action', () => {
    for (const s of [Status.SETTLED, Status.REFUNDED, Status.CANCELLED, Status.EXPIRED])
      for (const who of ['buyer', 'provider'] as const) expect(needs(rec(s), who)).toBe(false)
    expect(jobState(rec(Status.SETTLED), 'provider', T).label).toBe('Settled')
  })
})
