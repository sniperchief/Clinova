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
