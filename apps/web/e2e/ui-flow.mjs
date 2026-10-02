/**
 * Browser end-to-end test of the real UI against a LOCAL anvil fork of Arbitrum Sepolia.
 *
 * - anvil forks Arbitrum Sepolia (deployed Clinova bytecode, real Circle USDC state) on 127.0.0.1:8547
 * - the app runs under `vite` with VITE_ARB_SEPOLIA_RPC_URL pointing at the fork
 * - a TEST-ONLY EIP-1193 wallet shim is injected into the page; it forwards to anvil, where the public Phase 6
 *   test accounts are impersonated (no private keys exist anywhere). It is never part of the app bundle.
 * - system Microsoft Edge is driven by playwright-core
 *
 * Nothing is broadcast to the real network. Run: node e2e/ui-flow.mjs [screenshotDir]
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { chromium } from 'playwright-core'
import { createPublicClient, createTestClient, createWalletClient, erc20Abi, getAddress, http } from 'viem'
import { arbitrumSepolia } from 'viem/chains'

const ANVIL_PORT = 8547
const APP_PORT = 5175
const FORK = `http://127.0.0.1:${ANVIL_PORT}`
const APP = `http://127.0.0.1:${APP_PORT}`
const SHOTS = process.argv[2] || join(tmpdir(), 'clinova-e2e')
mkdirSync(SHOTS, { recursive: true })

const USDC = '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d'
const MARKETPLACE = '0x38d41cE5644Fbd12B8645472bAC00364EF306Ef0'
const REGISTRY = '0x8f6817E251cb23DaF5EcC064A4380B03D20E37ed'
const ESCROW = '0xcc66A42934450a67439cD7B999C3270C6BafFdef'
const BUYER = getAddress('0xfD858980c4Dc0F55919BACe10C25743a8218ED5B')
const OLD_PROVIDER = getAddress('0xd0091F4cc400E63C2401A026AFb2bC5DDEf0F94D')
const VERIFIER = getAddress('0xe95BA811aE6c6e16A9F1b16075966155B5Ea088D')
const PROVIDER = getAddress('0x00000000000000000000000000000000C11A0002')

const chain = { ...arbitrumSepolia, rpcUrls: { default: { http: [FORK] } } }
const pub = createPublicClient({ chain, transport: http(FORK) })
const wallet = createWalletClient({ chain, transport: http(FORK) })
const test = createTestClient({ chain, mode: 'anvil', transport: http(FORK) })
const children = []
const REGISTRY_MIN_STAKE = [{ type: 'function', name: 'minStake', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] }]
let minStake = 0n
const usdcText = (v) => (v % 1_000_000n === 0n ? (v / 1_000_000n).toString() : (Number(v) / 1e6).toString())
const results = []
let currentPage = null

function step(name) {
  results.push(name)
  console.log(`  ✓ ${name}`)
}

async function waitFor(fn, label, ms = 120_000) {
  const t0 = Date.now()
  for (;;) {
    try {
      if (await fn()) return
    } catch {
      /* not ready */
    }
    if (Date.now() - t0 > ms) throw new Error(`timeout: ${label}`)
    await new Promise((r) => setTimeout(r, 500))
  }
}

// ----------------------------------------------------------------------------------------------- setup

async function startAnvil() {
  const bin = [join(homedir(), '.foundry', 'bin', 'anvil.exe'), join(homedir(), '.foundry', 'bin', 'anvil')].find(existsSync) ?? 'anvil'
  children.push(spawn(bin, ['--fork-url', process.env.ARB_SEPOLIA_RPC_URL || 'https://sepolia-rollup.arbitrum.io/rpc', '--port', String(ANVIL_PORT), '--silent'], { stdio: 'ignore' }))
  await waitFor(async () => (await pub.getChainId()) === 421614, 'anvil')
}

async function startApp() {
  const vite = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--port', String(APP_PORT), '--host', '127.0.0.1', '--strictPort'], {
    env: { ...process.env, VITE_ARB_SEPOLIA_RPC_URL: FORK },
    stdio: 'ignore',
  })
  children.push(vite)
  await waitFor(async () => (await fetch(APP)).ok, 'vite')
}

async function sendAs(from, params) {
  const { request } = await pub.simulateContract({ ...params, account: from })
  const hash = await wallet.writeContract(request)
  const r = await pub.waitForTransactionReceipt({ hash })
  if (r.status !== 'success') throw new Error('setup tx failed')
}

/** Phase 6 leftovers: after the 8-day unbonding, close request #3 and release the old provider's stake. */
async function prepareFork() {
  for (const a of [BUYER, OLD_PROVIDER, VERIFIER, PROVIDER]) {
    await test.impersonateAccount({ address: a })
    await test.setBalance({ address: a, value: 10n ** 18n })
  }
  await test.increaseTime({ seconds: 8 * 24 * 3600 })
  await test.mine({ blocks: 1 })
  const abi = [{ type: 'function', name: 'expireRequest', stateMutability: 'nonpayable', inputs: [{ name: 'id', type: 'uint256' }], outputs: [] }]
  try {
    await sendAs(BUYER, { address: MARKETPLACE, abi, functionName: 'expireRequest', args: [3n] })
  } catch {
    /* already closed */
  }
  const withdraw = [{ type: 'function', name: 'withdraw', stateMutability: 'nonpayable', inputs: [], outputs: [{ type: 'uint256' }] }]
  const withdrawStake = [{ type: 'function', name: 'withdrawStake', stateMutability: 'nonpayable', inputs: [], outputs: [] }]
  try {
    await sendAs(BUYER, { address: ESCROW, abi: withdraw, functionName: 'withdraw' })
  } catch {
    /* nothing to withdraw */
  }
  await sendAs(OLD_PROVIDER, { address: REGISTRY, abi: withdrawStake, functionName: 'withdrawStake' })
  minStake = await pub.readContract({ address: REGISTRY, abi: REGISTRY_MIN_STAKE, functionName: 'minStake' })
  await sendAs(OLD_PROVIDER, { address: USDC, abi: erc20Abi, functionName: 'transfer', args: [PROVIDER, minStake] })
}

// ------------------------------------------------------------------------------------------- wallet shim

const WALLET_SHIM = ({ rpc, account }) => {
  const listeners = {}
  const state = { account: sessionStorage.getItem('__e2eAccount') || account, chainId: '0x66eee' }
  const emit = (ev, v) => (listeners[ev] || []).forEach((f) => f(v))
  window.__wallet = {
    setAccount(a) {
      state.account = a
      sessionStorage.setItem('__e2eAccount', a)
      emit('accountsChanged', [a])
    },
    setChain(id) {
      state.chainId = id
      emit('chainChanged', id)
    },
  }
  window.ethereum = {
    isMetaMask: false,
    on: (ev, f) => ((listeners[ev] ||= []).push(f), window.ethereum),
    removeListener: (ev, f) => ((listeners[ev] = (listeners[ev] || []).filter((x) => x !== f)), window.ethereum),
    async request({ method, params }) {
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [state.account]
      if (method === 'eth_chainId') return state.chainId
      if (method === 'wallet_switchEthereumChain') {
        window.__wallet.setChain(params[0].chainId)
        return null
      }
      if (method === 'wallet_requestPermissions' || method === 'wallet_revokePermissions') return []
      if (method === 'eth_sendTransaction' && state.chainId !== '0x66eee') throw Object.assign(new Error('wrong chain'), { code: 4901 })
      const res = await fetch(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) })
      const body = await res.json()
      if (body.error) throw Object.assign(new Error(body.error.message), { code: body.error.code, data: body.error.data })
      return body.result
    },
  }
}

// ------------------------------------------------------------------------------------------------ flow

async function main() {
  console.log('starting anvil fork + app…')
  await startAnvil()
  await prepareFork()
  await startApp()
  const chainNow = Number((await pub.getBlock()).timestamp) * 1000

  const browser = await chromium.launch({ channel: 'msedge', headless: true })
  children.push({ kill: () => browser.close().catch(() => {}) })
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } })
  context.setDefaultTimeout(60_000)
  await context.clock.install({ time: chainNow }) // browser clock = forked chain clock (8 days ahead)
  await context.addInitScript(WALLET_SHIM, { rpc: FORK, account: PROVIDER })
  const page = await context.newPage()
  currentPage = page
  page.on('dialog', (d) => d.accept())
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e)))
  const shot = (name) => page.screenshot({ path: join(SHOTS, `${name}.png`), fullPage: true })
  const as = async (addr) => page.evaluate((a) => window.__wallet.setAccount(a), addr)
  const go = async (path) => {
    await page.goto(APP + path)
  }
  const click = async (name, opts = {}) => {
    const b = page.getByRole('button', { name, exact: opts.exact ?? false }).first()
    await b.waitFor({ state: 'visible', timeout: 60_000 })
    await waitFor(() => b.isEnabled(), `enabled: ${name}`, 60_000)
    await b.click()
  }
  const see = (text, timeout = 60_000) => page.getByText(text, { exact: false }).first().waitFor({ state: 'visible', timeout })

  // Landing with live chain data
  await go('/')
  await see('Real-World Healthcare Infrastructure Layer')
  await waitFor(async () => (await page.locator('.live-panel .feed li').count()) >= 3, 'live activity feed')
  await shot('01-landing')
  step('landing page renders live network data and onchain activity from the fork')

  // Connect wallet
  await go('/provider')
  // RainbowKit may auto-connect the injected shim; otherwise connect through its picker.
  const onboarding = page.getByText('Become a Clinova provider').first()
  const connectBtn = page.locator('.nav').getByRole('button', { name: 'Connect wallet' })
  await onboarding.or(connectBtn).first().waitFor({ state: 'visible' })
  if (!(await onboarding.isVisible())) {
    await connectBtn.click()
    await click('Browser wallet')
  }
  await see('Become a Clinova provider')
  await see(`Minimum ${usdcText(minStake)} USDC, read from the ProviderRegistry contract`)
  step('wallet connects; provider onboarding reads minStake from the contract')

  // Wrong network handling
  await page.evaluate(() => window.__wallet.setChain('0x1'))
  await see('Clinova currently runs on Arbitrum Sepolia.')
  await shot('02-wrong-network')
  await page.locator('.banner').getByRole('button', { name: 'Switch network' }).click()
  await page.getByText('Clinova currently runs on Arbitrum Sepolia.').first().waitFor({ state: 'hidden' })
  step('wrong network shows a switch prompt and blocks transactions; switching restores')

  // Provider onboarding: approve → register
  await page.getByLabel('Business display name').fill('Demo Clinic E2E (synthetic)')
  await click(`Approve ${usdcText(minStake)} USDC`)
  await click('Register as provider')
  await see('Provider dashboard')
  await see('Awaiting verification')
  await shot('03-provider-registered')
  step(`provider approves USDC and registers + stakes ${usdcText(minStake)} USDC (the live minimum)`)

  // Verifier verifies the provider
  await as(VERIFIER)
  await go('/verifier')
  await see('Verification queue')
  const row = page.locator('tr', { hasText: 'Demo Clinic E2E' })
  await row.getByRole('button', { name: 'Verify' }).click()
  await see('No providers are waiting for verification.')
  await shot('04-verifier-queue')
  step('verifier dashboard detects VERIFIER_ROLE and verifies the provider')

  // Provider activates
  await as(PROVIDER)
  await go('/provider')
  await click('Activate', { exact: true })
  await page.locator('.dash-head .pill', { hasText: 'Accepting requests' }).waitFor()
  step('provider activates')

  // Buyer discovers and creates a request
  await as(BUYER)
  await go('/discover')
  await see('Demo Clinic E2E (synthetic)')
  await shot('05-discover')
  await go(`/buyer/new?provider=${PROVIDER}`)
  await see('New diagnostic request')
  await page.getByLabel('Payment').fill('25')
  await click('Approve 25 USDC')
  await click('Create request')
  await page.waitForURL(/\/requests\/\d+/, { timeout: 60_000 })
  const id = page.url().split('/').pop()
  await see('Awaiting provider')
  await shot('06-request-created')
  step(`buyer approves 25 USDC and creates + funds request #${id}`)

  // Provider: accept → start → proof
  await as(PROVIDER)
  await go(`/requests/${id}`)
  await click('Accept job')
  await click('Start service')
  await click('Use synthetic demo evidence')
  await see('Commitment')
  await click('Submit proof')
  await see('Proof submitted · awaiting review')
  await shot('07-proof-submitted')
  step('provider accepts, starts and submits a salted proof commitment')

  // Verifier: evidence check → approve
  await as(VERIFIER)
  await go('/verifier')
  await see('Commitment matches the onchain proof')
  await see('Manifest names this chain, contract, request and provider')
  await shot('08-verifier-review')
  await click('Approve', { exact: true })
  await see('No proofs are waiting for review.')
  step('verifier checks the evidence package against the onchain commitment and approves')

  // Provider withdraws, reputation updated
  await as(PROVIDER)
  await go('/provider')
  await page.locator('.callout', { hasText: 'Earnings ready' }).waitFor()
  const before = await pub.readContract({ address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: [PROVIDER] })
  await click('Withdraw earnings')
  await waitFor(async () => (await pub.readContract({ address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: [PROVIDER] })) === before + 25_000_000n, 'withdrawal')
  await page.locator('.callout', { hasText: 'Earnings ready' }).waitFor({ state: 'hidden' })
  await shot('09-provider-dashboard')
  step('provider withdraws exactly 25 USDC; dashboard updates')

  // Buyer sees settlement + reputation
  await as(BUYER)
  await go(`/requests/${id}`)
  await see('Settlement complete — verifier approved')
  await see('Outcome added to the provider’s reputation')
  await waitFor(async () => (await page.locator('.timeline a.ext').count()) >= 6, 'timeline tx links')
  const href = await page.locator('.timeline a.ext').first().getAttribute('href')
  if (!href?.startsWith('https://sepolia.arbiscan.io/tx/0x')) throw new Error(`bad explorer link ${href}`)
  await shot('10-settled')
  step('buyer sees settlement, reputation recorded and Arbiscan transaction links')

  // Responsive
  for (const [w, name] of [[390, 'mobile'], [820, 'tablet']]) {
    await page.setViewportSize({ width: w, height: 900 })
    for (const path of ['/', '/discover', `/requests/${id}`, '/buyer/new']) {
      await go(path)
      await page.waitForTimeout(800)
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
      if (overflow > 1) throw new Error(`horizontal overflow ${overflow}px on ${path} at ${w}px`)
    }
    await go('/')
    await shot(`11-${name}-landing`)
  }
  step('no horizontal overflow at 390px and 820px on landing, discover, request and form pages')

  if (errors.length) throw new Error(`page errors:\n${errors.join('\n')}`)
  await browser.close()
  console.log(`\n${results.length} UI checks passed. Screenshots: ${SHOTS}`)
}

main()
  .catch(async (e) => {
    await currentPage?.screenshot({ path: join(SHOTS, 'FAILURE.png'), fullPage: true }).catch(() => {})
    console.error('\nUI E2E FAILED:', e.message)
    console.error(`passed before failure: ${results.length}`)
    process.exitCode = 1
  })
  .finally(async () => {
    for (const c of children.reverse()) await c.kill()
    process.exit()
  })
