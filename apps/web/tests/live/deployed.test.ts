/**
 * Read-only integration test against the DEPLOYED Clinova contracts on Arbitrum Sepolia.
 * It runs the app's own read layer, call builders and error translation. Writes are only simulated with eth_call
 * from the public Phase 6 test addresses: no key is used, no gas is spent and no state changes.
 */
import { createPublicClient, erc20Abi, getAddress, http, type Address } from 'viem'
import { arbitrumSepolia } from 'viem/chains'
import { beforeAll, describe, expect, it } from 'vitest'
import { SERVICE_TYPES } from '../../src/config/catalog'
import { CLINOVA_ADDRESSES as A, PUBLIC_RPC_URL } from '../../src/config/contracts'
import { clinovaErrorsAbi } from '../../src/lib/contracts/abis'
import { calls, type ContractCall } from '../../src/lib/contracts/calls'
import {
  eventsForRequest,
  fetchAccount,
  fetchComputedProofHash,
  fetchEvents,
  fetchProtocol,
  fetchProviders,
  fetchRequests,
  type ClinovaEvent,
  type ProtocolState,
} from '../../src/lib/contracts/reads'
import { availableActions, outcomeSummary } from '../../src/lib/contracts/requestActions'
import { EscrowState, ProofStatus, Status, type RequestRecord } from '../../src/lib/contracts/types'
import { describeError } from '../../src/lib/errors'

const client = createPublicClient({ chain: arbitrumSepolia, transport: http(process.env.ARB_SEPOLIA_RPC_URL || PUBLIC_RPC_URL) })

// Public Phase 6 test accounts (docs/deployment-arbitrum-sepolia.md).
const BUYER = getAddress('0xfD858980c4Dc0F55919BACe10C25743a8218ED5B')
const PROVIDER = getAddress('0xd0091F4cc400E63C2401A026AFb2bC5DDEf0F94D')
const VERIFIER = getAddress('0xe95BA811aE6c6e16A9F1b16075966155B5Ea088D')
const ADMIN = getAddress('0xB4B8B6CD7C7adB5c68472A8092d2f7f747BF83C5')
const NOBODY = getAddress('0x000000000000000000000000000000000000dEaD')
const CBC = SERVICE_TYPES.find((s) => s.code === 'LAB.CBC.V1')!.hash

/** Simulates exactly as hooks/useTx.ts does, returning the translated error (or null on success). */
async function simulate(call: ContractCall, account: Address) {
  try {
    await client.simulateContract({
      address: call.address,
      abi: [...call.abi, ...clinovaErrorsAbi],
      functionName: call.functionName,
      args: call.args,
      account,
    } as Parameters<typeof client.simulateContract>[0])
    return null
  } catch (err) {
    return describeError(err)
  }
}

let protocol: ProtocolState
let events: ClinovaEvent[]
let requests: RequestRecord[]
const byId = (id: bigint) => requests.find((r) => r.id === id)!

beforeAll(async () => {
  protocol = await fetchProtocol(client)
  events = await fetchEvents(client)
  requests = await fetchRequests(client, protocol.nextRequestId)
})

describe('network and configuration', () => {
  it('talks to Arbitrum Sepolia and the configured contracts have code', async () => {
    expect(await client.getChainId()).toBe(421614)
    for (const addr of [A.serviceMarketplace, A.providerRegistry, A.clinovaEscrow, A.proofOfService, A.reputationRegistry, A.usdc])
      expect((await client.getCode({ address: addr }))?.length ?? 0).toBeGreaterThan(2)
  })

  it('the marketplace is wired to exactly the configured modules and USDC', async () => {
    const mkt = { address: A.serviceMarketplace, abi: calls.cancelRequest(1n).abi } as const
    const [registry, escrow, pos, rep] = await Promise.all(
      ['registry', 'escrow', 'proofOfService', 'reputation'].map((fn) => client.readContract({ ...mkt, functionName: fn } as never)),
    )
    expect([registry, escrow, pos, rep].map(String)).toEqual([A.providerRegistry, A.clinovaEscrow, A.proofOfService, A.reputationRegistry])
    expect(await client.readContract({ address: A.usdc, abi: erc20Abi, functionName: 'decimals' })).toBe(6)
    expect(await client.readContract({ address: A.usdc, abi: erc20Abi, functionName: 'symbol' })).toBe('USDC')
  })

  it('reads protocol parameters from the contracts (not hardcoded)', () => {
    // Admin-settable within the registry's hard bounds (0, 100,000 USDC]; deployed at 100 USDC.
    expect(protocol.minStake).toBeGreaterThan(0n)
    expect(protocol.minStake).toBeLessThanOrEqual(100_000_000_000n)
    expect(protocol.minPrice).toBe(1_000_000n)
    expect(protocol.unbondingPeriod).toBe(604_800n)
    expect(protocol.reviewPeriod).toBe(604_800)
    expect(protocol.disputePeriod).toBe(1_209_600)
    expect(protocol.nextRequestId).toBeGreaterThanOrEqual(6n)
    console.info('protocol', { ...protocol, paused: protocol.marketplacePaused })
  })
})

describe('provider discovery and reputation', () => {
  it('rebuilds the provider set from ProviderRegistered events', async () => {
    const providers = await fetchProviders(client, events, protocol.minStake)
    const p = providers.find((x) => x.address === PROVIDER)!
    expect(p).toBeDefined()
    expect(p.record.registered).toBe(true)
    expect(p.record.verified).toBe(true)
    expect(p.capabilities).toEqual([CBC])
    // Unbonding since Phase 6, so not eligible for new jobs.
    expect(p.record.unstakeAvailableAt).toBeGreaterThan(0n)
    expect(p.eligibleFor(CBC)).toBe(false)
    // Reputation counters straight from ReputationRegistry. Phase 6 left (3, 2, 1, 1); expiring request #3 adds a failure.
    expect(p.reputation.completedJobs).toBe(3n)
    expect(p.reputation.successfulJobs).toBe(2n)
    expect(p.reputation.failedJobs).toBeGreaterThanOrEqual(1n)
    expect(p.reputation.disputes).toBe(1n)
    console.info('provider reputation', p.reputation)
  })
})

describe('requests from the Phase 6 run', () => {
  it('reads request, escrow and proof state consistently', () => {
    const r1 = byId(1n)
    expect(r1.request.status).toBe(Status.SETTLED)
    expect(r1.request.price).toBe(25_000_000n)
    expect(r1.deposit.state).toBe(EscrowState.RELEASED)
    expect(r1.proof.status).toBe(ProofStatus.APPROVED)
    expect(r1.proof.reviewer).toBe(VERIFIER)
    expect(r1.outcomeRecorded).toBe(true)
    expect(outcomeSummary(r1, eventsForRequest(events, 1n))).toBe('Settlement complete — verifier approved')

    const r2 = byId(2n)
    expect(r2.request.status).toBe(Status.REFUNDED)
    expect(r2.proof.status).toBe(ProofStatus.REJECTED)
    expect(outcomeSummary(r2, eventsForRequest(events, 2n))).toBe('Resolved — buyer refunded (provider at fault)')

    expect(byId(4n).request.status).toBe(Status.CANCELLED)
    expect(outcomeSummary(byId(5n))).toBe('Settlement complete — buyer confirmed')
  })

  it('timeline events carry real transaction hashes', () => {
    const ev = eventsForRequest(events, 1n).map((e) => e.eventName)
    for (const name of ['ServiceRequestCreated', 'ServiceRequestAccepted', 'ServiceRequestStarted', 'ServiceRequestCompleted', 'ProofApproved', 'ServiceRequestSettled', 'OutcomeRecorded'])
      expect(ev).toContain(name)
    const created = eventsForRequest(events, 1n).find((e) => e.eventName === 'ServiceRequestCreated')!
    expect(created.transactionHash).toBe('0xe62e3fc44a539c5342e63e82b3233c86f0905f8a3992482a2dd7dfef994ab474')
  })

  it('the stored proof hash is the onchain binding of the commitment', async () => {
    const r1 = byId(1n)
    expect(await fetchComputedProofHash(client, 1n, r1.proof.provider, r1.proof.evidenceCommitment)).toBe(r1.proof.proofHash)
  })

  it('settled requests offer no actions to anyone (no “Confirm completion” after settlement)', () => {
    for (const account of [BUYER, PROVIDER, VERIFIER])
      expect(availableActions(byId(1n), { account, now: BigInt(Math.floor(Date.now() / 1000)), isVerifier: account === VERIFIER, marketplacePaused: false, isEligible: () => true })).toEqual([])
  })
})

describe('roles of the connected wallet', () => {
  it('detects verifier and pauser roles from the contracts', async () => {
    const v = await fetchAccount(client, VERIFIER)
    expect(v.isMarketplaceVerifier && v.isRegistryVerifier).toBe(true)
    const b = await fetchAccount(client, BUYER)
    expect(b.isMarketplaceVerifier || b.isRegistryVerifier).toBe(false)
    expect(b.provider.registered).toBe(false)
    expect((await fetchAccount(client, ADMIN)).isPauser).toBe(true)
  })
})

describe('simulated writes are decoded into plain language (eth_call, no gas)', () => {
  it('rejected actions explain themselves', async () => {
    expect((await simulate(calls.approveProof(1n), VERIFIER))?.message).toMatch(/“Settled”/)
    expect((await simulate(calls.confirmCompletion(1n), BUYER))?.message).toMatch(/“Settled”/)
    expect((await simulate(calls.approveProof(1n), BUYER))?.message).toMatch(/does not hold the role/)
    expect((await simulate(calls.withdrawCredit(), NOBODY))?.message).toMatch(/nothing to withdraw/)
    expect((await simulate(calls.withdrawStake(), PROVIDER))?.message).toMatch(/withdrawn after|active job/)
    expect((await simulate(calls.verifyProvider(PROVIDER), BUYER))?.message).toMatch(/does not hold the role/)
  })

  it('createRequest validation and the USDC approval requirement', async () => {
    const now = BigInt(Math.floor(Date.now() / 1000))
    const params = {
      directedProvider: '0x0000000000000000000000000000000000000000' as Address,
      serviceType: CBC,
      locationHash: SERVICE_TYPES[1].hash,
      price: 500_000n,
      acceptDeadline: now + 86_400n,
      serviceDeadline: now + 4n * 86_400n,
    }
    expect((await simulate(calls.createRequest(params), BUYER))?.message).toMatch(/below the protocol minimum of 1 USDC/)
    expect((await simulate(calls.createRequest({ ...params, price: 5_000_000n, acceptDeadline: now + 60n }), BUYER))?.message).toMatch(/outside the allowed windows/)
    // A valid request priced above the current allowance is rejected by Circle USDC with a string reason.
    const allowance = (await fetchAccount(client, BUYER)).allowanceMarketplace
    const price = allowance + 1_000_000n
    const noAllowance = await simulate(calls.createRequest({ ...params, price }), BUYER)
    expect(noAllowance?.message).toMatch(/not approved/)
    // The approval step itself would succeed, after which the same request simulates cleanly only if approved.
    expect(await simulate(calls.approveMarketplace(price), BUYER)).toBeNull()
    if (allowance >= 1_000_000n) expect(await simulate(calls.createRequest({ ...params, price: allowance }), BUYER)).toBeNull()
  })

  it('request #3: provider-fault expiry is gated by the service deadline', async () => {
    const r3 = byId(3n)
    const res = await simulate(calls.expireRequest(3n), BUYER)
    if (r3.request.status === Status.ACCEPTED && BigInt(Math.floor(Date.now() / 1000)) <= r3.request.serviceDeadline)
      expect(res?.message).toMatch(/only available after/)
    else if (r3.request.status === Status.ACCEPTED) expect(res).toBeNull()
    else expect(res?.message).toMatch(/does not allow this action/)
    // A stranger may never expire an accepted request.
    if (r3.request.status === Status.ACCEPTED) expect((await simulate(calls.expireRequest(3n), NOBODY))?.message).toMatch(/buyer or the assigned provider/)
  })
})
