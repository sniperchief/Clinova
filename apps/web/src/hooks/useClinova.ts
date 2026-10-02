import { useQuery } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import type { Hex } from 'viem'
import { useConnection, usePublicClient } from 'wagmi'
import { CLINOVA_CHAIN } from '../config/contracts'
import {
  fetchAccount,
  fetchEvents,
  fetchProtocol,
  fetchProviders,
  fetchRequest,
  fetchRequests,
} from '../lib/contracts/reads'
import { nowSeconds, sameAddress } from '../lib/format'

/** All protocol reads share this key prefix so a confirmed transaction can refresh everything at once. */
export const QK = 'clinova'
const POLL = 15_000

function useClient() {
  const client = usePublicClient({ chainId: CLINOVA_CHAIN.id })
  if (!client) throw new Error('Arbitrum Sepolia client is not configured')
  return client
}

export function useProtocol() {
  const client = useClient()
  return useQuery({ queryKey: [QK, 'protocol'], queryFn: () => fetchProtocol(client), refetchInterval: POLL })
}

export function useEvents() {
  const client = useClient()
  return useQuery({ queryKey: [QK, 'events'], queryFn: () => fetchEvents(client), refetchInterval: POLL })
}

export function useRequests() {
  const client = useClient()
  const next = useProtocol().data?.nextRequestId
  return useQuery({
    queryKey: [QK, 'requests', next?.toString()],
    queryFn: () => fetchRequests(client, next!),
    enabled: next !== undefined,
    refetchInterval: POLL,
    placeholderData: (prev) => prev,
  })
}

export function useRequest(id: bigint | null) {
  const client = useClient()
  return useQuery({
    queryKey: [QK, 'request', id?.toString()],
    queryFn: () => fetchRequest(client, id!),
    enabled: id !== null,
    refetchInterval: POLL,
  })
}

export function useProviders() {
  const client = useClient()
  const events = useEvents().data
  const minStake = useProtocol().data?.minStake
  return useQuery({
    queryKey: [QK, 'providers', events?.length, minStake?.toString()],
    queryFn: () => fetchProviders(client, events!, minStake!),
    enabled: events !== undefined && minStake !== undefined,
    refetchInterval: POLL,
    placeholderData: (prev) => prev,
  })
}

/** State of the connected wallet: balances, allowances, escrow credit, roles and its provider record. */
export function useAccountState() {
  const client = useClient()
  const { address } = useConnection()
  return useQuery({
    queryKey: [QK, 'account', address],
    queryFn: () => fetchAccount(client, address!),
    enabled: !!address,
    refetchInterval: POLL,
  })
}

/** Eligibility of the connected wallet for a service type, per the registry's rule. */
export function useSelfEligibility() {
  const { address } = useConnection()
  const providers = useProviders().data
  return useMemo(() => {
    const me = providers?.find((p) => sameAddress(p.address, address))
    return (serviceType: Hex) => !!me?.eligibleFor(serviceType)
  }, [providers, address])
}

/** Wall-clock seconds, ticking so deadline-gated actions appear without a reload. */
export function useNow(intervalMs = 15_000) {
  const [now, setNow] = useState(nowSeconds)
  useEffect(() => {
    const t = setInterval(() => setNow(nowSeconds()), intervalMs)
    return () => clearInterval(t)
  }, [intervalMs])
  return now
}

export function useIsVerifier() {
  const account = useAccountState().data
  return !!account?.isMarketplaceVerifier
}

export function useWrongNetwork() {
  const { isConnected, chainId } = useConnection()
  return isConnected && chainId !== CLINOVA_CHAIN.id
}
