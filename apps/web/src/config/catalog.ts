import { getAddress, keccak256, toBytes, type Address, type Hex } from 'viem'

/**
 * Public catalogs used by this frontend to give human names to onchain bytes32 codes.
 *
 * Service types are public catalog codes (docs/architecture.md): serviceType = keccak256("LAB.CBC.V1").
 * Regions are coarse, effectively public service-area codes, never a patient address:
 * locationHash = keccak256("CLINOVA_REGION_V1:<code>").
 *
 * The contracts do not store names, so any code not in these lists is shown as its raw hash.
 */

export interface ServiceType {
  code: string
  name: string
  short: string
  hash: Hex
}

const service = (code: string, name: string, short: string): ServiceType => ({
  code,
  name,
  short,
  hash: keccak256(toBytes(code)),
})

export const SERVICE_TYPES: ServiceType[] = [
  service('LAB.CBC.V1', 'Complete blood count', 'CBC'),
  service('LAB.MALARIA_RDT.V1', 'Malaria rapid test', 'Malaria RDT'),
  service('LAB.FBS.V1', 'Fasting blood glucose', 'Blood glucose'),
  service('LAB.LIPID.V1', 'Lipid panel', 'Lipid panel'),
  service('LAB.HBA1C.V1', 'HbA1c', 'HbA1c'),
  service('LAB.URINALYSIS.V1', 'Urinalysis', 'Urinalysis'),
]

export interface Region {
  code: string
  name: string
  hash: Hex
}

export const regionHash = (code: string): Hex => keccak256(toBytes(`CLINOVA_REGION_V1:${code}`))

const region = (code: string, name: string): Region => ({ code, name, hash: regionHash(code) })

export const REGIONS: Region[] = [
  region('NG-RI:PortHarcourt', 'Port Harcourt, NG'),
  region('NG-LA:Lagos', 'Lagos, NG'),
  region('NG-FC:Abuja', 'Abuja, NG'),
  region('NG-OY:Ibadan', 'Ibadan, NG'),
  region('NG-KN:Kano', 'Kano, NG'),
  region('NG-EN:Enugu', 'Enugu, NG'),
  region('GH-AA:Accra', 'Accra, GH'),
  region('KE-30:Nairobi', 'Nairobi, KE'),
]

export const serviceByHash = (hash: Hex): ServiceType | undefined =>
  SERVICE_TYPES.find((s) => s.hash === hash.toLowerCase())

export const regionByHash = (hash: Hex): Region | undefined => REGIONS.find((r) => r.hash === hash.toLowerCase())

/**
 * SYNTHETIC demo labels for addresses used during the Phase 6 testnet run. These are presentation-only, are not
 * stored onchain, and do not describe real organisations. Protocol state for these accounts still comes from chain.
 */
export const DEMO_DIRECTORY: Record<Address, { label: string; note: string }> = {
  [getAddress('0xd0091F4cc400E63C2401A026AFb2bC5DDEf0F94D')]: {
    label: 'Demo Diagnostic Center',
    note: 'Synthetic demo provider from the Phase 6 testnet run (Port Harcourt). Its onchain region is a salted hash, so it cannot be matched to this catalog.',
  },
  [getAddress('0xfD858980c4Dc0F55919BACe10C25743a8218ED5B')]: {
    label: 'Demo Telehealth Buyer',
    note: 'Synthetic demo buyer from the Phase 6 testnet run.',
  },
  [getAddress('0xe95BA811aE6c6e16A9F1b16075966155B5Ea088D')]: {
    label: 'Clinova Testnet Verifier',
    note: 'Holds VERIFIER_ROLE on the registry and marketplace.',
  },
}
