import { bytesToHex, encodeAbiParameters, keccak256, toBytes, type Address, type Hex } from 'viem'

/**
 * Offchain commitment construction. Nothing here sends data anywhere: hashes are computed in the browser and
 * only the resulting 32-byte commitment is submitted onchain.
 *
 * Evidence (docs/contract-spec.md §5):
 *   evidenceCommitment = keccak256(abi.encode("CLINOVA_EVIDENCE_V1", evidenceBundleHash, salt))
 * The bundle carries a manifest naming chainId, ProofOfService, requestId and provider (R5-3), which the
 * verifier checks before approving.
 */

/** Deterministic JSON (sorted keys) so the same record always hashes the same way. */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(',')}}`
}

export function randomSalt(): Hex {
  return bytesToHex(crypto.getRandomValues(new Uint8Array(32)))
}

const saltedCommitment = (domain: string, contentHash: Hex, salt: Hex): Hex =>
  keccak256(
    encodeAbiParameters([{ type: 'string' }, { type: 'bytes32' }, { type: 'bytes32' }], [domain, contentHash, salt]),
  )

// ---------------------------------------------------------------------------------------------------------------
// Evidence
// ---------------------------------------------------------------------------------------------------------------

export interface EvidenceManifest {
  chainId: number
  proofOfService: Address
  requestId: string
  provider: Address
}

export interface EvidenceBundle {
  v: 'CLINOVA_EVIDENCE_V1'
  manifest: EvidenceManifest
  /** keccak256 of the evidence file bytes. The file itself never leaves the provider's device. */
  evidenceFileHash: Hex
  synthetic: boolean
}

/** What the provider keeps and hands to the verifier through the offchain verification channel. */
export interface EvidencePackage {
  bundle: EvidenceBundle
  bundleHash: Hex
  salt: Hex
  evidenceCommitment: Hex
}

/** keccak256(abi.encode("CLINOVA_EVIDENCE_V1", evidenceBundleHash, salt)), exactly as spec section 5. */
export const evidenceCommitment = (bundleHash: Hex, salt: Hex): Hex => saltedCommitment('CLINOVA_EVIDENCE_V1', bundleHash, salt)

export function buildEvidencePackage(
  manifest: EvidenceManifest,
  evidenceFileHash: Hex,
  synthetic: boolean,
  salt: Hex = randomSalt(),
): EvidencePackage {
  const bundle: EvidenceBundle = { v: 'CLINOVA_EVIDENCE_V1', manifest, evidenceFileHash, synthetic }
  const bundleHash = keccak256(toBytes(canonicalJson(bundle)))
  return { bundle, bundleHash, salt, evidenceCommitment: evidenceCommitment(bundleHash, salt) }
}

export async function hashFile(file: Blob): Promise<Hex> {
  return keccak256(new Uint8Array(await file.arrayBuffer()))
}

/** A synthetic evidence document for demos. Contains no patient data by construction. */
export function syntheticEvidenceFile(requestId: bigint): Blob {
  const doc = {
    synthetic: true,
    notice: 'SYNTHETIC DEMO EVIDENCE. Not a medical record. Contains no patient information.',
    requestId: requestId.toString(),
    sampleReference: `DEMO-${requestId}-${bytesToHex(crypto.getRandomValues(new Uint8Array(4))).slice(2)}`,
    generatedAt: new Date().toISOString(),
  }
  return new Blob([JSON.stringify(doc, null, 2)], { type: 'application/json' })
}

export interface EvidenceCheck {
  commitmentMatches: boolean
  manifestMatches: boolean
  problems: string[]
}

/** Verifier-side check of a package against onchain state (spec §5, R5-3). */
export function checkEvidencePackage(
  pkg: EvidencePackage,
  expected: EvidenceManifest,
  onchainCommitment: Hex,
): EvidenceCheck {
  const problems: string[] = []
  const bundleHash = keccak256(toBytes(canonicalJson(pkg.bundle)))
  if (bundleHash !== pkg.bundleHash) problems.push('The bundle does not hash to the stated bundle hash.')
  const recomputed = evidenceCommitment(bundleHash, pkg.salt)
  const commitmentMatches = recomputed.toLowerCase() === onchainCommitment.toLowerCase()
  if (!commitmentMatches) problems.push('The recomputed commitment does not match the onchain commitment.')
  const m = pkg.bundle.manifest
  const manifestMatches =
    m.chainId === expected.chainId &&
    m.proofOfService.toLowerCase() === expected.proofOfService.toLowerCase() &&
    m.requestId === expected.requestId &&
    m.provider.toLowerCase() === expected.provider.toLowerCase()
  if (!manifestMatches) problems.push('The manifest names a different chain, contract, request or provider.')
  return { commitmentMatches, manifestMatches, problems }
}

// ---------------------------------------------------------------------------------------------------------------
// Dispute / rejection reasons (bytes32 references to an offchain record, salted)
// ---------------------------------------------------------------------------------------------------------------

export interface ReasonRecord {
  v: 'CLINOVA_REASON_V1'
  requestId: string
  category: string
  note: string
}

export function buildReason(requestId: bigint, category: string, note: string, salt: Hex = randomSalt()) {
  const record: ReasonRecord = { v: 'CLINOVA_REASON_V1', requestId: requestId.toString(), category, note }
  const recordHash = keccak256(toBytes(canonicalJson(record)))
  return { record, salt, reasonHash: saltedCommitment('CLINOVA_REASON_V1', recordHash, salt) }
}

// ---------------------------------------------------------------------------------------------------------------
// Provider profile (published business information; documented as public, so not salted)
// ---------------------------------------------------------------------------------------------------------------

export interface ProviderProfile {
  v: 'CLINOVA_PROFILE_V1'
  name: string
  region: string
  website?: string
}

export const profileHash = (profile: ProviderProfile): Hex => keccak256(toBytes(canonicalJson(profile)))
