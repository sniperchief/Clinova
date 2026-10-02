import { describe, expect, it } from 'vitest'
import { formatUsdc, parseUsdc } from '../format'

describe('USDC amounts (integer base units, 6 decimals)', () => {
  it('parses decimal input exactly', () => {
    expect(parseUsdc('25')).toBe(25_000_000n)
    expect(parseUsdc('25.5')).toBe(25_500_000n)
    expect(parseUsdc('0.000001')).toBe(1n)
    expect(parseUsdc(' 100 ')).toBe(100_000_000n)
    // Values that are inexact in floating point stay exact.
    expect(parseUsdc('0.3')).toBe(300_000n)
    expect(parseUsdc('123456789.123456')).toBe(123_456_789_123_456n)
  })

  it('rejects anything that is not a plain decimal', () => {
    for (const bad of ['', '-1', '1e6', '1.0000001', 'abc', '1,000', '0x10', '.5', 'NaN']) expect(parseUsdc(bad)).toBeNull()
  })

  it('formats without floating point', () => {
    expect(formatUsdc(25_000_000n)).toBe('25')
    expect(formatUsdc(1_234_567_891n)).toBe('1,234.567891')
    expect(formatUsdc(100_000_000_000n)).toBe('100,000')
    expect(formatUsdc(1n)).toBe('0.000001')
    expect(formatUsdc(0n)).toBe('0')
    expect(formatUsdc(2n ** 128n - 1n)).toBe('340,282,366,920,938,463,463,374,607,431,768.211455')
  })
})
