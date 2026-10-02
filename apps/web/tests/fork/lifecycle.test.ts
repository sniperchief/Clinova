/**
 * Full write lifecycle on a LOCAL anvil fork of Arbitrum Sepolia: the deployed Clinova bytecode and the real Circle
 * USDC state, with the public Phase 6 test accounts impersonated (no private keys). Nothing is broadcast to the real
 * network. Every transaction goes through the app's call builders (src/lib/contracts/calls.ts), is simulated with the
 * same error ABI as hooks/useTx.ts, and state is re-read through the app's read layer after each step.
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  erc20Abi,
  getAddress,
  http,
  keccak256,
  parseEventLogs,
  toBytes,
  type Address,
  type PublicClient,
} from 'viem'
import { arbitrumSepolia } from 'viem/chains'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { regionHash, SERVICE_TYPES } from '../../src/config/catalog'
import { CLINOVA_ADDRESSES as A, PUBLIC_RPC_URL } from '../../src/config/contracts'
import { buildEvidencePackage, buildReason, checkEvidencePackage, profileHash } from '../../src/lib/commitments'
import { clinovaErrorsAbi, serviceMarketplaceAbi } from '../../src/lib/contracts/abis'
import { calls, type ContractCall } from '../../src/lib/contracts/calls'
import {
  fetchAccount,
  fetchEvents,
  fetchProtocol,
  fetchProviders,
  fetchRequest,
  resetEventCache,
} from '../../src/lib/contracts/reads'
import { availableActions, outcomeSummary } from '../../src/lib/contracts/requestActions'
import { EscrowState, ProofStatus, Resolution, Status } from '../../src/lib/contracts/types'
import { describeError } from '../../src/lib/errors'

const PORT = 8546
const FORK_RPC = `http://127.0.0.1:${PORT}`
const chain = { ...arbitrumSepolia, rpcUrls: { default: { http: [FORK_RPC] } } }

const BUYER = getAddress('0xfD858980c4Dc0F55919BACe10C25743a8218ED5B')
const OLD_PROVIDER = getAddress('0xd0091F4cc400E63C2401A026AFb2bC5DDEf0F94D')
const VERIFIER = getAddress('0xe95BA811aE6c6e16A9F1b16075966155B5Ea088D')
const ADMIN = getAddress('0xB4B8B6CD7C7adB5c68472A8092d2f7f747BF83C5')
// A brand-new provider wallet that exists only on the fork.
const NEW_PROVIDER = getAddress('0x00000000000000000000000000000000C11A0001')
const CBC = SERVICE_TYPES.find((s) => s.code === 'LAB.CBC.V1')!.hash
const MALARIA = SERVICE_TYPES.find((s) => s.code === 'LAB.MALARIA_RDT.V1')!.hash
const PH = regionHash('NG-RI:PortHarcourt')
const USDC = (n: number) => BigInt(n) * 1_000_000n

let anvil: ChildProcess
let pub: PublicClient
const wallet = createWalletClient({ chain, transport: http(FORK_RPC) })
const test = createTestClient({ chain, mode: 'anvil', transport: http(FORK_RPC) })
const txs: Record<string, string> = {}

async function send(label: string, call: ContractCall, from: Address) {
  const { request } = await pub.simulateContract({
    address: call.address,
    abi: [...call.abi, ...clinovaErrorsAbi],
    functionName: call.functionName,
    args: call.args,
    account: from,
  } as Parameters<PublicClient['simulateContract']>[0])
  const hash = await wallet.writeContract(request as Parameters<typeof wallet.writeContract>[0])
  const receipt = await pub.waitForTransactionReceipt({ hash })
  expect(receipt.status, label).toBe('success')
  txs[label] = hash
  return receipt
}

async function rejects(call: ContractCall, from: Address) {
  try {
    await pub.simulateContract({
      address: call.address,
      abi: [...call.abi, ...clinovaErrorsAbi],
      functionName: call.functionName,
      args: call.args,
      account: from,
    } as Parameters<PublicClient['simulateContract']>[0])
  } catch (err) {
    return describeError(err).message
  }
  throw new Error('expected a revert')
}

const usdcOf = (a: Address) => pub.readContract({ address: A.usdc, abi: erc20Abi, functionName: 'balanceOf', args: [a] })
const now = async () => (await pub.getBlock()).timestamp
async function warp(seconds: number) {
  await test.increaseTime({ seconds })
  await test.mine({ blocks: 1 })
}

beforeAll(async () => {
  const bin = [join(homedir(), '.foundry', 'bin', 'anvil.exe'), join(homedir(), '.foundry', 'bin', 'anvil')].find(existsSync) ?? 'anvil'
  anvil = spawn(bin, ['--fork-url', process.env.ARB_SEPOLIA_RPC_URL || PUBLIC_RPC_URL, '--port', String(PORT), '--silent'], { stdio: 'ignore' })
  pub = createPublicClient({ chain, transport: http(FORK_RPC) }) as PublicClient
  for (let i = 0; i < 120; i++) {
    try {
      await pub.getChainId()
      break
    } catch {
      await new Promise((r) => setTimeout(r, 500))
    }
  }
  expect(await pub.getChainId()).toBe(421614)
  for (const a of [BUYER, OLD_PROVIDER, VERIFIER, ADMIN, NEW_PROVIDER]) {
    await test.impersonateAccount({ address: a })
    await test.setBalance({ address: a, value: 10n ** 18n }) // gas only; USDC is never minted
  }
  resetEventCache()
})

afterAll(() => {
  anvil?.kill()
  console.info('fork transactions', txs)
})

describe('Clinova lifecycle on an Arbitrum Sepolia fork', () => {
  it('closes Phase 6 leftovers: buyer expires request #3 (provider fault) and both parties withdraw', async () => {
    await warp(8 * 24 * 3600) // past request #3's service deadline and the provider's unbonding period
    const before = await fetchAccount(pub, BUYER)
    const r3 = await fetchRequest(pub, 3n)
    if (r3.request.status === Status.ACCEPTED) {
      expect(availableActions(r3, { account: BUYER, now: await now(), isVerifier: false, marketplacePaused: false, isEligible: () => false }).map((a) => a.id)).toEqual(['expireAccepted'])
      await send('expire #3', calls.expireRequest(3n), BUYER)
    }
    const after3 = await fetchRequest(pub, 3n)
    expect(after3.request.status).toBe(Status.EXPIRED)
    expect(outcomeSummary(after3)).toBe('Expired — provider missed the service deadline, buyer refunded')
    const credit = (await fetchAccount(pub, BUYER)).escrowCredit
    if (credit > 0n) {
      await send('buyer withdraw refund', calls.withdrawCredit(), BUYER)
      expect(await usdcOf(BUYER)).toBe(before.usdcBalance + credit)
    }
    // Old provider: unbonding is over and no jobs remain open, so the full stake can be withdrawn.
    const p = await fetchAccount(pub, OLD_PROVIDER)
    if (p.provider.stake > 0n) {
      await send('old provider withdrawStake', calls.withdrawStake(), OLD_PROVIDER)
      expect(await usdcOf(OLD_PROVIDER)).toBe(p.usdcBalance + p.provider.stake)
    }
  })

  it('onboards a new provider: approve → register+stake → verify → activate', async () => {
    const protocol = await fetchProtocol(pub)
    // Fund the new wallet with real (forked) USDC from the old provider, by an ordinary transfer.
    await send('fund new provider', { address: A.usdc, abi: erc20Abi, functionName: 'transfer', args: [NEW_PROVIDER, protocol.minStake] }, OLD_PROVIDER)

    const profile = { v: 'CLINOVA_PROFILE_V1' as const, name: 'Demo Diagnostic Center Two (synthetic)', region: 'NG-RI:PortHarcourt' }
    expect(await rejects(calls.register(profileHash(profile), PH, [CBC], protocol.minStake), NEW_PROVIDER)).toMatch(/not approved/)
    await send('approve registry', calls.approveRegistry(protocol.minStake), NEW_PROVIDER)
    await send('register', calls.register(profileHash(profile), PH, [CBC, MALARIA], protocol.minStake), NEW_PROVIDER)

    let me = await fetchAccount(pub, NEW_PROVIDER)
    expect(me.provider).toMatchObject({ registered: true, verified: false, active: false, stake: protocol.minStake, metadataHash: profileHash(profile) })
    expect(await rejects(calls.activate(), NEW_PROVIDER)).toMatch(/must be verified/)
    expect(await rejects(calls.verifyProvider(NEW_PROVIDER), NEW_PROVIDER)).toMatch(/does not hold the role/)

    await send('verify', calls.verifyProvider(NEW_PROVIDER), VERIFIER)
    await send('activate', calls.activate(), NEW_PROVIDER)
    me = await fetchAccount(pub, NEW_PROVIDER)
    expect(me.provider).toMatchObject({ verified: true, active: true })

    resetEventCache()
    const providers = await fetchProviders(pub, await fetchEvents(pub), protocol.minStake)
    const listed = providers.find((p) => p.address === NEW_PROVIDER)!
    expect(listed.capabilities.sort()).toEqual([CBC, MALARIA].sort())
    expect(listed.eligibleFor(CBC)).toBe(true)
  })

  let requestId = 0n

  it('buyer: approve USDC → create and fund a directed request', async () => {
    const t = await now()
    const create = calls.createRequest({
      directedProvider: NEW_PROVIDER,
      serviceType: CBC,
      locationHash: PH,
      price: USDC(25),
      acceptDeadline: t + 86_400n,
      serviceDeadline: t + 4n * 86_400n,
    })
    const allowance = (await fetchAccount(pub, BUYER)).allowanceMarketplace
    if (allowance < USDC(25)) expect(await rejects(create, BUYER)).toMatch(/not approved/)
    await send('approve marketplace', calls.approveMarketplace(USDC(25)), BUYER)
    const escrowBefore = await usdcOf(A.clinovaEscrow)
    const receipt = await send('create+fund', create, BUYER)
    const [ev] = parseEventLogs({ abi: serviceMarketplaceAbi, eventName: 'ServiceRequestCreated', logs: receipt.logs })
    requestId = ev.args.id
    const rec = await fetchRequest(pub, requestId)
    expect(rec.request.status).toBe(Status.OPEN)
    expect(rec.deposit).toMatchObject({ state: EscrowState.FUNDED, amount: USDC(25), payer: BUYER })
    expect(await usdcOf(A.clinovaEscrow)).toBe(escrowBefore + USDC(25))
  })

  it('provider: accept → start → submit proof (salted commitment)', async () => {
    expect(await rejects(calls.acceptRequest(requestId), OLD_PROVIDER)).toMatch(/assigned to this request/)
    await send('accept', calls.acceptRequest(requestId), NEW_PROVIDER)
    expect((await fetchRequest(pub, requestId)).deposit.payee).toBe(NEW_PROVIDER)
    await send('start', calls.startService(requestId), NEW_PROVIDER)

    const pkg = buildEvidencePackage(
      { chainId: 421614, proofOfService: A.proofOfService, requestId: requestId.toString(), provider: NEW_PROVIDER },
      keccak256(toBytes('SYNTHETIC DEMO EVIDENCE — no patient data')),
      true,
    )
    await send('submit proof', calls.submitProof(requestId, pkg.evidenceCommitment), NEW_PROVIDER)
    const rec = await fetchRequest(pub, requestId)
    expect(rec.request.status).toBe(Status.COMPLETED)
    expect(rec.proof.status).toBe(ProofStatus.SUBMITTED)
    expect(rec.proof.evidenceCommitment).toBe(pkg.evidenceCommitment)
    // The verifier-side check accepts the package against onchain state.
    expect(checkEvidencePackage(pkg, { chainId: 421614, proofOfService: A.proofOfService, requestId: requestId.toString(), provider: rec.proof.provider }, rec.proof.evidenceCommitment).problems).toEqual([])
    // A second proof for the same request is rejected.
    expect(await rejects(calls.submitProof(requestId, pkg.evidenceCommitment), NEW_PROVIDER)).toMatch(/does not allow this action/)
  })

  it('verifier approves → settlement; provider withdraws; reputation updates', async () => {
    expect(await rejects(calls.approveProof(requestId), BUYER)).toMatch(/does not hold the role/)
    await send('approve proof', calls.approveProof(requestId), VERIFIER)
    const rec = await fetchRequest(pub, requestId)
    expect(rec.request.status).toBe(Status.SETTLED)
    expect(rec.deposit.state).toBe(EscrowState.RELEASED)
    expect(rec.proof.status).toBe(ProofStatus.APPROVED)
    expect(rec.outcomeRecorded).toBe(true)
    expect(outcomeSummary(rec)).toBe('Settlement complete — verifier approved')
    // Once settled the UI offers nothing, and the contract agrees.
    expect(availableActions(rec, { account: BUYER, now: await now(), isVerifier: false, marketplacePaused: false, isEligible: () => false })).toEqual([])
    expect(await rejects(calls.confirmCompletion(requestId), BUYER)).toMatch(/“Settled”/)

    const me = await fetchAccount(pub, NEW_PROVIDER)
    expect(me.escrowCredit).toBe(USDC(25))
    await send('provider withdraw', calls.withdrawCredit(), NEW_PROVIDER)
    expect(await usdcOf(NEW_PROVIDER)).toBe(me.usdcBalance + USDC(25))
    expect(await rejects(calls.withdrawCredit(), NEW_PROVIDER)).toMatch(/nothing to withdraw/)
    expect((await fetchAccount(pub, NEW_PROVIDER)).reputation).toEqual({ completedJobs: 1n, successfulJobs: 1n, failedJobs: 0n, disputes: 0n })
  })

  it('dispute path: buyer disputes → verifier refunds (no fault) → buyer withdraws', async () => {
    const t = await now()
    await send('approve 2', calls.approveMarketplace(USDC(5)), BUYER)
    const receipt = await send(
      'create 2 (open)',
      calls.createRequest({ directedProvider: '0x0000000000000000000000000000000000000000', serviceType: CBC, locationHash: PH, price: USDC(5), acceptDeadline: t + 7200n, serviceDeadline: t + 7200n + 6n * 3600n }),
      BUYER,
    )
    const [ev] = parseEventLogs({ abi: serviceMarketplaceAbi, eventName: 'ServiceRequestCreated', logs: receipt.logs })
    const id = ev.args.id
    await send('accept 2', calls.acceptRequest(id), NEW_PROVIDER)
    const reason = buildReason(id, 'Service not delivered', 'synthetic demo')
    await send('dispute 2', calls.openDispute(id, reason.reasonHash), BUYER)
    let rec = await fetchRequest(pub, id)
    expect(rec.request.status).toBe(Status.DISPUTED)
    // No proof is under review, so the provider cannot win this dispute (spec T13).
    expect(await rejects(calls.resolveDispute(id, Resolution.PROVIDER_WINS), VERIFIER)).toMatch(/no longer under review/)
    const before = await fetchAccount(pub, BUYER)
    await send('resolve 2', calls.resolveDispute(id, Resolution.REFUND_NO_FAULT), VERIFIER)
    rec = await fetchRequest(pub, id)
    expect(rec.request.status).toBe(Status.REFUNDED)
    resetEventCache()
    const events = (await fetchEvents(pub)).filter((e) => e.args.id === id || e.args.requestId === id)
    expect(outcomeSummary(rec, events)).toBe('Resolved — buyer refunded (no fault)')
    await send('buyer withdraw 2', calls.withdrawCredit(), BUYER)
    expect(await usdcOf(BUYER)).toBe(before.usdcBalance + before.escrowCredit + USDC(5))
    expect((await fetchAccount(pub, NEW_PROVIDER)).reputation).toEqual({ completedJobs: 1n, successfulJobs: 1n, failedJobs: 0n, disputes: 1n })
  })

  it('pause: new requests are blocked with a clear message; refunds still work', async () => {
    const t = await now()
    await send('approve 3', calls.approveMarketplace(USDC(2)), BUYER)
    const receipt = await send(
      'create 3',
      calls.createRequest({ directedProvider: '0x0000000000000000000000000000000000000000', serviceType: CBC, locationHash: PH, price: USDC(2), acceptDeadline: t + 7200n, serviceDeadline: t + 7200n + 6n * 3600n }),
      BUYER,
    )
    const [ev] = parseEventLogs({ abi: serviceMarketplaceAbi, eventName: 'ServiceRequestCreated', logs: receipt.logs })
    await send('pause', { address: A.serviceMarketplace, abi: serviceMarketplaceAbi, functionName: 'pause' }, ADMIN)
    expect((await fetchProtocol(pub)).marketplacePaused).toBe(true)
    expect(await rejects(calls.acceptRequest(ev.args.id), NEW_PROVIDER)).toMatch(/temporarily paused/)
    await send('cancel while paused', calls.cancelRequest(ev.args.id), BUYER)
    await send('withdraw while paused', calls.withdrawCredit(), BUYER)
    await send('unpause', { address: A.serviceMarketplace, abi: serviceMarketplaceAbi, functionName: 'unpause' }, ADMIN)
    expect((await fetchProtocol(pub)).marketplacePaused).toBe(false)
  })
})
