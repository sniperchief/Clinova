import { useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import type { Hex, TransactionReceipt } from 'viem'
import { useConfig, useAccount, type Config } from 'wagmi'
import { simulateContract, waitForTransactionReceipt, writeContract } from 'wagmi/actions'
import { CLINOVA_CHAIN } from '../config/contracts'
import { clinovaErrorsAbi } from '../lib/contracts/abis'
import type { ContractCall } from '../lib/contracts/calls'
import { describeError, type FriendlyError } from '../lib/errors'
import { QK } from './useClinova'

/**
 * checking   – simulated against the live contract before the wallet opens (catches reverts with no gas spent)
 * wallet     – waiting for the user to sign
 * confirming – broadcast; waiting for the receipt
 * confirmed  – receipt has status "success"
 * failed     – rejected, reverted in simulation, or reverted onchain
 */
export type TxPhase = 'idle' | 'checking' | 'wallet' | 'confirming' | 'confirmed' | 'failed'

export interface TxState {
  phase: TxPhase
  hash?: Hex
  error?: FriendlyError
}

// Call descriptors carry a generic `Abi` (they are built centrally in lib/contracts/calls.ts from the generated
// ABIs), so the actions are used through a loosened signature rather than per-function inferred types.
type LooseParams = Record<string, unknown>
const simulate = simulateContract as unknown as (c: Config, p: LooseParams) => Promise<{ request: LooseParams }>
const write = writeContract as unknown as (c: Config, p: LooseParams) => Promise<Hex>

export function useTx() {
  const config = useConfig()
  const queryClient = useQueryClient()
  const { address, chainId } = useAccount()
  const [state, setState] = useState<TxState>({ phase: 'idle' })

  const run = useCallback(
    async (call: ContractCall): Promise<TransactionReceipt | null> => {
      if (!address) {
        setState({ phase: 'failed', error: { message: 'Connect a wallet first.', technical: 'no account' } })
        return null
      }
      // Never send on the wrong chain. writeContract also asserts the chain, as a second guard.
      if (chainId !== CLINOVA_CHAIN.id) {
        setState({
          phase: 'failed',
          error: {
            message: 'Clinova runs on Arbitrum Sepolia. Switch network and try again.',
            technical: `wallet chainId ${chainId}`,
          },
        })
        return null
      }
      try {
        setState({ phase: 'checking' })
        const { request } = await simulate(config, {
          address: call.address,
          abi: [...call.abi, ...clinovaErrorsAbi],
          functionName: call.functionName,
          args: call.args,
          account: address,
          chainId: CLINOVA_CHAIN.id,
        })
        setState({ phase: 'wallet' })
        const hash = await write(config, request)
        setState({ phase: 'confirming', hash })
        const receipt = await waitForTransactionReceipt(config, { hash, chainId: CLINOVA_CHAIN.id })
        if (receipt.status !== 'success') {
          setState({
            phase: 'failed',
            hash,
            error: { message: 'The transaction was reverted onchain. No state changed.', technical: `receipt status ${receipt.status}` },
          })
          return null
        }
        setState({ phase: 'confirmed', hash })
        await queryClient.invalidateQueries({ queryKey: [QK] })
        return receipt
      } catch (err) {
        setState((s) => ({ phase: 'failed', hash: s.hash, error: describeError(err) }))
        return null
      }
    },
    [address, chainId, config, queryClient],
  )

  const reset = useCallback(() => setState({ phase: 'idle' }), [])
  const busy = state.phase === 'checking' || state.phase === 'wallet' || state.phase === 'confirming'
  return { ...state, run, reset, busy }
}
