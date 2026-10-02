import {
  erc20Abi,
  keccak256,
  parseEventLogs,
  toBytes,
  type Abi,
  type Address,
  type Hex,
  type Log,
  type PublicClient,
} from 'viem'
import { CLINOVA_ADDRESSES as A, DEPLOYMENT_BLOCK } from '../../config/contracts'
import {
  clinovaEscrowAbi,
  proofOfServiceAbi,
  providerRegistryAbi,
  reputationRegistryAbi,
  serviceMarketplaceAbi,
} from './abis'
import type { Deposit, ProviderRecord, Reputation, RequestRecord, ServiceProof, ServiceRequest } from './types'

/**
 * Every read of protocol state. Plain functions over a viem PublicClient so the same code runs in the app
 * (through react-query hooks) and in the fork integration test. No caching of protocol state beyond react-query.
 */

export const VERIFIER_ROLE = keccak256(toBytes('VERIFIER_ROLE'))
export const PAUSER_ROLE = keccak256(toBytes('PAUSER_ROLE'))

const mkt = { address: A.serviceMarketplace, abi: serviceMarketplaceAbi } as const
const reg = { address: A.providerRegistry, abi: providerRegistryAbi } as const
const esc = { address: A.clinovaEscrow, abi: clinovaEscrowAbi } as const
const pos = { address: A.proofOfService, abi: proofOfServiceAbi } as const
const rep = { address: A.reputationRegistry, abi: reputationRegistryAbi } as const

export interface ProtocolState {
  marketplacePaused: boolean
  registryPaused: boolean
  minStake: bigint
  unbondingPeriod: bigint
  minPrice: bigint
  reviewPeriod: number
  disputePeriod: number
  nextRequestId: bigint
  totalLocked: bigint
  totalStaked: bigint
  blockNumber: bigint
}

export async function fetchProtocol(client: PublicClient): Promise<ProtocolState> {
  const [r, blockNumber] = await Promise.all([
    client.multicall({
      allowFailure: false,
      contracts: [
        { ...mkt, functionName: 'paused' },
        { ...reg, functionName: 'paused' },
        { ...reg, functionName: 'minStake' },
        { ...reg, functionName: 'unbondingPeriod' },
        { ...mkt, functionName: 'minPrice' },
        { ...mkt, functionName: 'reviewPeriod' },
        { ...mkt, functionName: 'disputePeriod' },
        { ...mkt, functionName: 'nextRequestId' },
        { ...esc, functionName: 'totalLocked' },
        { ...reg, functionName: 'totalStaked' },
      ],
    }),
    client.getBlockNumber(),
  ])
  return {
    marketplacePaused: r[0],
    registryPaused: r[1],
    minStake: r[2],
    unbondingPeriod: BigInt(r[3]),
    minPrice: r[4],
    reviewPeriod: Number(r[5]),
    disputePeriod: Number(r[6]),
    nextRequestId: r[7],
    totalLocked: r[8],
    totalStaked: r[9],
    blockNumber,
  }
}

/** Reads every request (ids 1..nextRequestId-1) with its deposit and proof. */
export async function fetchRequests(client: PublicClient, nextRequestId: bigint): Promise<RequestRecord[]> {
  const ids: bigint[] = []
  for (let i = 1n; i < nextRequestId; i++) ids.push(i)
  if (ids.length === 0) return []
  const results = await client.multicall({
    allowFailure: false,
    contracts: ids.flatMap((id) => [
      { ...mkt, functionName: 'getRequest', args: [id] } as const,
      { ...esc, functionName: 'getDeposit', args: [id] } as const,
      { ...pos, functionName: 'getProof', args: [id] } as const,
      { ...rep, functionName: 'outcomeRecorded', args: [id] } as const,
    ]),
  })
  return ids.map((id, i) => {
    const raw = results.slice(i * 4, i * 4 + 4)
    return {
      id,
      request: raw[0] as unknown as ServiceRequest,
      deposit: raw[1] as unknown as Deposit,
      proof: raw[2] as unknown as ServiceProof,
      outcomeRecorded: raw[3] as boolean,
    }
  })
}

export async function fetchRequest(client: PublicClient, id: bigint): Promise<RequestRecord> {
  const [request, deposit, proof, outcomeRecorded] = await client.multicall({
    allowFailure: false,
    contracts: [
      { ...mkt, functionName: 'getRequest', args: [id] },
      { ...esc, functionName: 'getDeposit', args: [id] },
      { ...pos, functionName: 'getProof', args: [id] },
      { ...rep, functionName: 'outcomeRecorded', args: [id] },
    ],
  })
  return {
    id,
    request: request as unknown as ServiceRequest,
    deposit: deposit as unknown as Deposit,
    proof: proof as unknown as ServiceProof,
    outcomeRecorded,
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Event history (provider discovery, per-request timelines and transaction links)
// ---------------------------------------------------------------------------------------------------------------

const eventAbi = [
  ...serviceMarketplaceAbi,
  ...providerRegistryAbi,
  ...clinovaEscrowAbi,
  ...proofOfServiceAbi,
  ...reputationRegistryAbi,
].filter((item) => item.type === 'event') as Abi

export interface ClinovaEvent {
  eventName: string
  args: Record<string, unknown>
  address: Address
  blockNumber: bigint
  transactionHash: Hex
  logIndex: number
}

const LOG_CHUNK = 2_000_000n
let logCache: { client: PublicClient; toBlock: bigint; events: ClinovaEvent[] } | null = null

async function getLogsChunked(client: PublicClient, fromBlock: bigint, toBlock: bigint): Promise<Log[]> {
  const address = [A.serviceMarketplace, A.providerRegistry, A.clinovaEscrow, A.proofOfService, A.reputationRegistry]
  try {
    return await client.getLogs({ address, fromBlock, toBlock })
  } catch (err) {
    // Some RPCs cap the block range. Fall back to fixed-size chunks.
    if (toBlock - fromBlock <= LOG_CHUNK) throw err
    const logs: Log[] = []
    for (let start = fromBlock; start <= toBlock; start += LOG_CHUNK + 1n) {
      const end = start + LOG_CHUNK > toBlock ? toBlock : start + LOG_CHUNK
      logs.push(...(await client.getLogs({ address, fromBlock: start, toBlock: end })))
    }
    return logs
  }
}

/** All Clinova events since deployment, fetched incrementally. */
export async function fetchEvents(client: PublicClient): Promise<ClinovaEvent[]> {
  const latest = await client.getBlockNumber()
  if (logCache && logCache.client !== client) logCache = null
  if (logCache && latest <= logCache.toBlock) return logCache.events
  const from = logCache ? logCache.toBlock + 1n : DEPLOYMENT_BLOCK
  const logs = await getLogsChunked(client, from, latest)
  const parsed = parseEventLogs({ abi: eventAbi, logs, strict: false }).map(
    (l) =>
      ({
        eventName: l.eventName,
        args: (l.args ?? {}) as Record<string, unknown>,
        address: l.address,
        blockNumber: l.blockNumber!,
        transactionHash: l.transactionHash!,
        logIndex: l.logIndex!,
      }) satisfies ClinovaEvent,
  )
  const events = [...(logCache?.events ?? []), ...parsed]
  logCache = { client, toBlock: latest, events }
  return events
}

export function resetEventCache() {
  logCache = null
}

/** Events that concern one request id, oldest first. */
export function eventsForRequest(events: ClinovaEvent[], id: bigint): ClinovaEvent[] {
  return events.filter((e) => {
    const a = e.args
    if (e.address.toLowerCase() === A.serviceMarketplace.toLowerCase()) return a.id === id
    return a.requestId === id
  })
}

// ---------------------------------------------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------------------------------------------

export interface ProviderView {
  address: Address
  record: ProviderRecord
  reputation: Reputation
  capabilities: Hex[]
  /** True for a service type when eligible(provider, serviceType) holds per the registry's own rule. */
  eligibleFor: (serviceType: Hex) => boolean
  registeredAt?: { blockNumber: bigint; transactionHash: Hex }
}

/** Providers are not enumerable onchain; the set is rebuilt from ProviderRegistered events. */
export async function fetchProviders(
  client: PublicClient,
  events: ClinovaEvent[],
  minStake: bigint,
): Promise<ProviderView[]> {
  const registered = new Map<Address, ClinovaEvent>()
  const claimed = new Map<Address, Set<Hex>>()
  for (const e of events) {
    if (e.eventName === 'ProviderRegistered') registered.set(e.args.provider as Address, e)
    if (e.eventName === 'ProviderCapabilityAdded') {
      const p = e.args.provider as Address
      if (!claimed.has(p)) claimed.set(p, new Set())
      claimed.get(p)!.add(e.args.serviceType as Hex)
    }
  }
  const providers = [...registered.keys()]
  if (providers.length === 0) return []

  const pairs = providers.flatMap((p) => [...(claimed.get(p) ?? [])].map((t) => [p, t] as const))
  const results = await client.multicall({
    allowFailure: false,
    contracts: [
      ...providers.flatMap((p) => [
        { ...reg, functionName: 'getProvider', args: [p] } as const,
        { ...rep, functionName: 'getReputation', args: [p] } as const,
      ]),
      ...pairs.map(([p, t]) => ({ ...reg, functionName: 'offersService', args: [p, t] }) as const),
    ],
  })

  const offered = new Map<Address, Hex[]>()
  pairs.forEach(([p, t], i) => {
    if (results[providers.length * 2 + i]) offered.set(p, [...(offered.get(p) ?? []), t])
  })

  return providers.map((address, i) => {
    const record = results[i * 2] as unknown as ProviderRecord
    const reputation = results[i * 2 + 1] as unknown as Reputation
    const capabilities = offered.get(address) ?? []
    const baseEligible =
      record.registered &&
      record.verified &&
      record.active &&
      record.unstakeAvailableAt === 0n &&
      record.stake >= minStake
    const ev = registered.get(address)!
    return {
      address,
      record,
      reputation,
      capabilities,
      eligibleFor: (t: Hex) => baseEligible && capabilities.some((c) => c.toLowerCase() === t.toLowerCase()),
      registeredAt: { blockNumber: ev.blockNumber, transactionHash: ev.transactionHash },
    }
  })
}

// ---------------------------------------------------------------------------------------------------------------
// Connected account
// ---------------------------------------------------------------------------------------------------------------

export interface AccountState {
  ethBalance: bigint
  usdcBalance: bigint
  allowanceMarketplace: bigint
  allowanceRegistry: bigint
  escrowCredit: bigint
  isMarketplaceVerifier: boolean
  isRegistryVerifier: boolean
  isPauser: boolean
  provider: ProviderRecord
  reputation: Reputation
}

export async function fetchAccount(client: PublicClient, account: Address): Promise<AccountState> {
  const usdcC = { address: A.usdc, abi: erc20Abi } as const
  const [r, ethBalance] = await Promise.all([
    client.multicall({
      allowFailure: false,
      contracts: [
        { ...usdcC, functionName: 'balanceOf', args: [account] },
        { ...usdcC, functionName: 'allowance', args: [account, A.serviceMarketplace] },
        { ...usdcC, functionName: 'allowance', args: [account, A.providerRegistry] },
        { ...esc, functionName: 'credit', args: [account] },
        { ...mkt, functionName: 'hasRole', args: [VERIFIER_ROLE, account] },
        { ...reg, functionName: 'hasRole', args: [VERIFIER_ROLE, account] },
        { ...mkt, functionName: 'hasRole', args: [PAUSER_ROLE, account] },
        { ...reg, functionName: 'getProvider', args: [account] },
        { ...rep, functionName: 'getReputation', args: [account] },
      ],
    }),
    client.getBalance({ address: account }),
  ])
  return {
    ethBalance,
    usdcBalance: r[0],
    allowanceMarketplace: r[1],
    allowanceRegistry: r[2],
    escrowCredit: r[3],
    isMarketplaceVerifier: r[4],
    isRegistryVerifier: r[5],
    isPauser: r[6],
    provider: r[7] as unknown as ProviderRecord,
    reputation: r[8] as unknown as Reputation,
  }
}

export async function fetchComputedProofHash(client: PublicClient, id: bigint, provider: Address, commitment: Hex) {
  return client.readContract({ ...pos, functionName: 'computeProofHash', args: [id, provider, commitment] })
}
