/**
 * Vitest Test Setup
 *
 * Runs before all tests. Configures environment and cleanup.
 */

// Mock ResizeObserver (not available in jsdom)
// Must be defined before any React imports
class ResizeObserverMock {
  observe() {}
  unobserve() {}
  disconnect() {}
}
;(globalThis as typeof globalThis & { ResizeObserver: typeof ResizeObserverMock }).ResizeObserver = ResizeObserverMock

// Mock matchMedia (not available in jsdom)
// Used by useReducedMotion hook
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: (query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  }),
})

import { afterEach, beforeEach } from 'vitest'
import { cleanup } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { useReaperStore } from '../store'

// Clean up DOM after each test
afterEach(() => {
  cleanup()
})

// Reset store state before each test (belt and suspenders with setupStore)
beforeEach(() => {
  useReaperStore.setState({
    selectedRegionIds: [],
    timelineMode: 'navigate',
  })
})
