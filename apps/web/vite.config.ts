import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('node_modules/viem') || id.includes('node_modules/@noble')) return 'viem'
          if (id.includes('node_modules/wagmi') || id.includes('node_modules/@wagmi')) return 'wagmi'
        },
      },
    },
  },
})
