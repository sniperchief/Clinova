import { defineConfig } from 'vitest/config'

// Unit tests only. Network tests: `npm run test:live` (Arbitrum Sepolia, read-only) and `npm run test:fork` (anvil fork).
export default defineConfig({ test: { include: ['src/**/*.test.ts'] } })
