import { getAddress } from 'viem'
import { DEMO_DIRECTORY } from '../config/catalog'
import type { ProviderRecord } from './contracts/types'
import { loadProfile } from './localRecords'

/** Display name from presentation-only metadata, if any. Never from protocol state. */
export function providerLabel(p: { address: string; record: ProviderRecord }): { name: string | null; source: string } {
  const profile = loadProfile(p.record.metadataHash)
  if (profile) return { name: profile.name, source: 'Profile matches the onchain metadata commitment' }
  const demo = DEMO_DIRECTORY[getAddress(p.address)]
  if (demo) return { name: demo.label, source: demo.note }
  return { name: null, source: 'No offchain profile available in this browser' }
}

export type AvailabilityTone = 'ok' | 'warn' | 'muted'

/** Plain-language availability derived from the registry record (same rule as onchain eligibility). */
export function providerAvailability(record: ProviderRecord, minStake?: bigint): { label: string; tone: AvailabilityTone } {
  if (!record.registered) return { label: 'Not registered', tone: 'muted' }
  if (record.unstakeAvailableAt > 0n) return { label: 'Leaving the network', tone: 'muted' }
  if (!record.verified) return { label: 'Awaiting verification', tone: 'warn' }
  if (minStake !== undefined && record.stake < minStake) return { label: 'Stake below minimum', tone: 'warn' }
  if (!record.active) return { label: 'Paused by provider', tone: 'muted' }
  return { label: 'Accepting requests', tone: 'ok' }
}

/** Two-letter monogram for a display name, or null when there is no name. */
export function monogram(name: string | null): string | null {
  if (!name) return null
  const words = name.replace(/\(.*?\)/g, '').trim().split(/\s+/).filter(Boolean)
  return (words.length > 1 ? words[0][0] + words[1][0] : (words[0] ?? '').slice(0, 2)).toUpperCase() || null
}
