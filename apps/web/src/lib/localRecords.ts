import type { Hex } from 'viem'
import { profileHash, type EvidencePackage, type ProviderProfile, type ReasonRecord } from './commitments'

/**
 * Browser-local, PRESENTATION-ONLY records: offchain documents whose hashes are committed onchain.
 * Never protocol state. Every record is checked against its onchain hash before it is displayed.
 * They live only in this browser; another device will not see them.
 */

const PREFIX = 'clinova.v1.'

function read<T>(key: string): T | null {
  try {
    const raw = localStorage.getItem(PREFIX + key)
    return raw ? (JSON.parse(raw) as T) : null
  } catch {
    return null
  }
}

function write(key: string, value: unknown) {
  try {
    localStorage.setItem(PREFIX + key, JSON.stringify(value))
  } catch {
    // Storage unavailable (private mode, blocked). The onchain flow does not depend on it.
  }
}

export function saveProfile(profile: ProviderProfile) {
  write(`profile.${profileHash(profile)}`, profile)
}

/** Returns the profile only if it hashes to the onchain metadataHash. */
export function loadProfile(metadataHash: Hex): ProviderProfile | null {
  const p = read<ProviderProfile>(`profile.${metadataHash.toLowerCase()}`)
  return p && profileHash(p) === metadataHash.toLowerCase() ? p : null
}

export const saveEvidence = (requestId: bigint, pkg: EvidencePackage) => write(`evidence.${requestId}`, pkg)
export const loadEvidence = (requestId: bigint) => read<EvidencePackage>(`evidence.${requestId}`)

export interface StoredReason {
  record: ReasonRecord
  salt: Hex
  reasonHash: Hex
}
export const saveReason = (r: StoredReason) => write(`reason.${r.reasonHash}`, r)
export const loadReason = (reasonHash: Hex) => read<StoredReason>(`reason.${reasonHash.toLowerCase()}`)

export function downloadJson(filename: string, value: unknown) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2)], { type: 'application/json' }))
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}
