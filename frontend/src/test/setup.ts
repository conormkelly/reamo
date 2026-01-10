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
global.ResizeObserver = ResizeObserverMock

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
    pendingChanges: {},
    selectedRegionIds: [],
    dragType: 'none',
    dragRegionId: null,
    dragStartX: null,
    dragStartTime: null,
    dragCurrentTime: null,
    insertionPoint: null,
    resizeEdgePosition: null,
    isCommitting: false,
    commitError: null,
  })
})
