import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { viteSingleFile } from 'vite-plugin-singlefile'
import { resolve } from 'path'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  build: {
    target: 'esnext',
    // Output to dist folder
    outDir: 'dist',
    // Inline all assets
    assetsInlineLimit: 100000000,
    cssCodeSplit: false,
    rollupOptions: {
      input: {
        // Main entry point (can be used for dev)
        main: resolve(__dirname, 'index.html'),
        // Add more pages here as needed:
        // 'hello-world': resolve(__dirname, 'pages/hello-world/index.html'),
      },
    },
  },
  resolve: {
    alias: {
      '@': resolve(__dirname, 'src'),
    },
  },
})
