import { formatUnits, parseUnits, type Address, type Hex } from 'viem'
import { EXPLORER_URL, USDC_DECIMALS } from '../config/contracts'

// All token math is bigint base units. Strings are only produced for display, never parsed back.

const USDC_INPUT = /^\d{1,12}(\.\d{0,6})?$/

/** Parse a user-typed USDC amount into base units. Returns null for anything that is not a plain decimal. */
export function parseUsdc(input: string): bigint | null {
  const trimmed = input.trim()
  if (!USDC_INPUT.test(trimmed)) return null
  return parseUnits(trimmed, USDC_DECIMALS)
}

/** 25000000n -> "25", 1234567891n -> "1,234.567891". Exact; no floating point. */
export function formatUsdc(amount: bigint, opts: { maxDecimals?: number } = {}): string {
  const negative = amount < 0n
  const [whole, frac = ''] = formatUnits(negative ? -amount : amount, USDC_DECIMALS).split('.')
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  const decimals = opts.maxDecimals === undefined ? frac : frac.slice(0, opts.maxDecimals)
  const trimmed = decimals.replace(/0+$/, '')
  return `${negative ? '-' : ''}${grouped}${trimmed ? `.${trimmed}` : ''}`
}

export const usdc = (amount: bigint) => `${formatUsdc(amount)} USDC`

export const shortAddress = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`
export const shortHash = (h: string) => `${h.slice(0, 10)}…${h.slice(-6)}`

export const ZERO_ADDRESS: Address = '0x0000000000000000000000000000000000000000'
export const isZeroAddress = (a: string) => a.toLowerCase() === ZERO_ADDRESS
export const sameAddress = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase()

export const txUrl = (hash: Hex) => `${EXPLORER_URL}/tx/${hash}`
export const addressUrl = (address: string) => `${EXPLORER_URL}/address/${address}`

export const nowSeconds = () => BigInt(Math.floor(Date.now() / 1000))

export function formatDateTime(unix: bigint | number): string {
  if (BigInt(unix) === 0n) return '—'
  return new Date(Number(unix) * 1000).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

/** "in 3h 20m", "2d ago". Display only. */
export function formatRelative(unix: bigint, now: bigint = nowSeconds()): string {
  const diff = Number(unix - now)
  const abs = Math.abs(diff)
  const d = Math.floor(abs / 86400)
  const h = Math.floor((abs % 86400) / 3600)
  const m = Math.floor((abs % 3600) / 60)
  const span = d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : m > 0 ? `${m}m` : `${abs}s`
  return diff >= 0 ? `in ${span}` : `${span} ago`
}

export function formatDuration(seconds: number | bigint): string {
  const s = Number(seconds)
  if (s % 86400 === 0) return `${s / 86400} day${s === 86400 ? '' : 's'}`
  if (s % 3600 === 0) return `${s / 3600} hours`
  return `${Math.round(s / 60)} minutes`
}

/** Unix seconds -> value for <input type="datetime-local"> in local time. */
export function toDateTimeLocal(unix: number): string {
  const d = new Date(unix * 1000)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

export function fromDateTimeLocal(value: string): number | null {
  const ms = new Date(value).getTime()
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null
}
