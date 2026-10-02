import '@rainbow-me/rainbowkit/styles.css'
import { darkTheme, RainbowKitProvider, type Theme } from '@rainbow-me/rainbowkit'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { WagmiProvider } from 'wagmi'
import { App } from './App'
import { CLINOVA_CHAIN } from './config/contracts'
import './index.css'
import { wagmiConfig } from './lib/web3/wagmi'

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 5_000, retry: 2, refetchOnWindowFocus: true } },
})

/** RainbowKit's dark theme, matched to Clinova's green-tinted surfaces and white primary actions. */
const base = darkTheme({
  accentColor: '#ffffff',
  accentColorForeground: '#02090a',
  borderRadius: 'large',
  fontStack: 'system',
  overlayBlur: 'small',
})
const clinovaTheme: Theme = {
  ...base,
  colors: {
    ...base.colors,
    modalBackground: '#041e18',
    modalBorder: '#1e2c31',
    modalText: '#ffffff',
    modalTextSecondary: '#99b3ad',
    modalTextDim: '#71717a',
    profileForeground: '#041e18',
    actionButtonSecondaryBackground: '#072720',
    actionButtonBorder: '#1e2c31',
    generalBorder: '#1e2c31',
    generalBorderDim: '#093329',
    menuItemBackground: '#072720',
    closeButtonBackground: '#072720',
    closeButton: '#99b3ad',
    connectButtonBackground: '#041e18',
    connectButtonInnerBackground: '#072720',
    modalBackdrop: 'rgba(2, 9, 10, 0.72)',
    selectedOptionBorder: '#36f4a4',
  },
  fonts: { body: "'Inter Variable', ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif" },
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={clinovaTheme} initialChain={CLINOVA_CHAIN} modalSize="compact" appInfo={{ appName: 'Clinova' }}>
          <App />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
)
