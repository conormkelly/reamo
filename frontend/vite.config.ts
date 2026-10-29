import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { visualizer } from 'rollup-plugin-visualizer'
import { resolve } from 'path'

// https://vite.dev/config/
export default defineConfig(({ mode }) => ({
  plugins: [
    react(),
    mode === 'analyze' && visualizer({
      open: true,
      filename: 'bundle-stats.html',
      gzipSize: true,
      brotliSize: true,
    }),
  ].filter(Boolean),
  build: {
    // Vite's default target (Chrome 111, Firefox 114, Safari/iOS 16.4) for JS
    // and CSS. Lightning CSS minifies against it, so it keeps the -webkit-
    // prefixes Safari still needs, such as -webkit-backdrop-filter before 18.
    target: 'baseline-widely-available',
    outDir: 'dist',
    rolldownOptions: {
      input: {
        // Main entry point (can be used for dev)
        main: resolve(import.meta.dirname, 'index.html'),
        // Add more pages here as needed:
        // 'hello-world': resolve(import.meta.dirname, 'pages/hello-world/index.html'),
      },
      output: {
        // Production builds drop calls to console methods and debugger
        // statements. An object here replaces Vite's `minify: true`; Oxc keeps
        // compress, mangle and codegen on for any key left unset.
        minify: mode === 'production'
          ? { compress: { dropConsole: true, dropDebugger: true } }
          : undefined,
      },
    },
  },
  resolve: {
    alias: {
      '@': resolve(import.meta.dirname, 'src'),
    },
  },
}))
