import { keccak256, toBytes, type Hex } from 'viem'
import { describe, expect, it } from 'vitest'
import { SERVICE_TYPES } from '../../config/catalog'
import { CLINOVA_ADDRESSES } from '../../config/contracts'
import {
  buildEvidencePackage,
  buildReason,
  canonicalJson,
  checkEvidencePackage,
  evidenceCommitment,
  profileHash,
} from '../commitments'
import { VERIFIER_ROLE } from '../contracts/reads'

const B: Hex = `0x${'11'.repeat(32)}`
const S: Hex = `0x${'22'.repeat(32)}`
const manifest = {
  chainId: 421614,
  proofOfService: CLINOVA_ADDRESSES.proofOfService,
  requestId: '7',
  provider: '0xd0091F4cc400E63C2401A026AFb2bC5DDEf0F94D' as const,
}

describe('commitments match the Solidity encoding', () => {
  it('evidence commitment equals keccak256(abi.encode("CLINOVA_EVIDENCE_V1", bundleHash, salt))', () => {
    // Reference value from Foundry:
    //   cast keccak $(cast abi-encode "f(string,bytes32,bytes32)" "CLINOVA_EVIDENCE_V1" 0x11..11 0x22..22)
    expect(evidenceCommitment(B, S)).toBe('0x593693a192adf2cdeb37823a6ce2418d6806ade63cf990724e07baa819676c8f')
  })

  it('catalog codes and role ids match the contracts', () => {
    expect(SERVICE_TYPES.find((s) => s.code === 'LAB.CBC.V1')!.hash).toBe(
      '0xc1e244af2ae6f212b483b9fcfea4b2f0b1c3fa64e1989cc2d1db7c395ef2b5e0',
    )
    // ServiceMarketplace.VERIFIER_ROLE() as read from Arbitrum Sepolia.
    expect(VERIFIER_ROLE).toBe('0x0ce23c3e399818cfee81a7ab0880f714e53d7672b08df0fa62f2843416e1ea09')
  })
})

describe('evidence packages', () => {
  it('a package verifies against its own commitment and manifest', () => {
    const pkg = buildEvidencePackage(manifest, keccak256(toBytes('synthetic file')), true, S)
    expect(checkEvidencePackage(pkg, manifest, pkg.evidenceCommitment)).toEqual({
      commitmentMatches: true,
      manifestMatches: true,
      problems: [],
    })
  })

  it('detects a wrong commitment, a tampered bundle, and a manifest for another request (R5-3)', () => {
    const pkg = buildEvidencePackage(manifest, keccak256(toBytes('synthetic file')), true, S)
    expect(checkEvidencePackage(pkg, manifest, B).commitmentMatches).toBe(false)
    expect(checkEvidencePackage(pkg, { ...manifest, requestId: '8' }, pkg.evidenceCommitment).manifestMatches).toBe(false)
    const tampered = { ...pkg, bundle: { ...pkg.bundle, evidenceFileHash: B } }
    expect(checkEvidencePackage(tampered, manifest, pkg.evidenceCommitment).commitmentMatches).toBe(false)
  })

  it('uses a fresh random salt by default, so identical evidence gives different commitments', () => {
    const f = keccak256(toBytes('same'))
    expect(buildEvidencePackage(manifest, f, true).evidenceCommitment).not.toBe(
      buildEvidencePackage(manifest, f, true).evidenceCommitment,
    )
  })
})

describe('reasons and profiles', () => {
  it('reason hashes are salted', () => {
    expect(buildReason(1n, 'Service not delivered', '').reasonHash).not.toBe(buildReason(1n, 'Service not delivered', '').reasonHash)
    expect(buildReason(1n, 'x', '', S).reasonHash).toBe(buildReason(1n, 'x', '', S).reasonHash)
  })

  it('canonical JSON is key-order independent', () => {
    expect(canonicalJson({ b: 1, a: [2, { d: 1, c: 2 }] })).toBe('{"a":[2,{"c":2,"d":1}],"b":1}')
    expect(profileHash({ v: 'CLINOVA_PROFILE_V1', name: 'A', region: 'R' })).toBe(
      profileHash({ region: 'R', name: 'A', v: 'CLINOVA_PROFILE_V1' }),
    )
  })
})
