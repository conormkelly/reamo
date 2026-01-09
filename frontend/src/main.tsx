import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'

createRoot(document.getElementById('root')!, {
  // React 19 error callbacks - surface errors that would otherwise be silent
  onUncaughtError: (error, errorInfo) => {
    // Uncaught errors (not caught by ErrorBoundary)
    console.error('[React] Uncaught error:', error, errorInfo);
  },
  onCaughtError: (error, errorInfo) => {
    // Errors caught by ErrorBoundary - log for debugging
    console.warn('[React] Caught by ErrorBoundary:', error, errorInfo);
  },
}).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
