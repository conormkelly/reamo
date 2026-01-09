/**
 * DOM Query Utilities
 *
 * Helpers for finding and inspecting elements in rendered components.
 * Uses data-testid and data-* attributes for resilient selectors.
 *
 * Convention:
 * - data-testid: element type (e.g., "region-block", "region-label")
 * - data-region-id: REAPER region ID for lookup
 * - data-region-name: region name for debugging
 * - data-selected/data-dragging/data-pending/data-new: state attributes
 */

// ============================================================================
// Element Finders
// ============================================================================

/**
 * Find a region element by its name (uses data-region-name attribute)
 */
export function findRegionElement(container: HTMLElement, name: string): HTMLElement | null {
  // First try data attribute (preferred)
  const byAttr = container.querySelector(`[data-region-name="${name}"]`)
  if (byAttr) return byAttr as HTMLElement

  // Fallback: search span text content (for backwards compatibility)
  const allText = container.querySelectorAll('span')
  for (const span of allText) {
    if (span.textContent?.trim() === name) {
      // Walk up to find the positioned parent (the region container)
      let el = span.parentElement
      while (el && el !== container) {
        const style = el.style
        if (style.left || style.width) {
          return el as HTMLElement
        }
        el = el.parentElement
      }
    }
  }
  return null
}

/**
 * Find a region element by its ID (uses data-region-id attribute)
 */
export function findRegionById(container: HTMLElement, id: number): HTMLElement | null {
  return container.querySelector(`[data-region-id="${id}"]`)
}

/**
 * Find all region elements (uses data-testid attribute)
 */
export function findAllRegionElements(container: HTMLElement): HTMLElement[] {
  // First try data-testid (preferred)
  const byTestId = container.querySelectorAll('[data-testid="region-block"], [data-testid="region-label"]')
  if (byTestId.length > 0) {
    return Array.from(byTestId) as HTMLElement[]
  }

  // Fallback: style-based detection (for backwards compatibility)
  const elements: HTMLElement[] = []
  const candidates = container.querySelectorAll('[style*="left"]')
  for (const el of candidates) {
    const style = (el as HTMLElement).style
    if (style.left && style.width) {
      elements.push(el as HTMLElement)
    }
  }
  return elements
}

/**
 * Find all region blocks (main timeline area, not labels)
 */
export function findAllRegionBlocks(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll('[data-testid="region-block"]'))
}

/**
 * Find all region labels (top bar labels)
 */
export function findAllRegionLabels(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll('[data-testid="region-label"]'))
}

/**
 * Find marker element by name or ID
 */
export function findMarkerElement(container: HTMLElement, nameOrId: string | number): HTMLElement | null {
  const selector = typeof nameOrId === 'number'
    ? `[data-marker-id="${nameOrId}"]`
    : `[data-marker-name="${nameOrId}"]`
  return container.querySelector(selector)
}

/**
 * Find the playhead element
 */
export function findPlayhead(container: HTMLElement): HTMLElement | null {
  // Playhead typically has a distinctive class or data attribute
  return container.querySelector('[data-playhead]') as HTMLElement | null
}

/**
 * Find the timeline container
 */
export function findTimeline(container: HTMLElement): HTMLElement | null {
  return container.querySelector('[data-timeline]') as HTMLElement | null
}

// ============================================================================
// Visual State Queries
// ============================================================================

/**
 * Check if element appears selected (uses data-selected attribute)
 */
export function isVisuallySelected(element: HTMLElement): boolean {
  // First check data attribute (preferred)
  if (element.hasAttribute('data-selected')) {
    return true
  }
  // Fallback: class-based check (for backwards compatibility)
  const cls = element.className
  return cls.includes('border-accent-region') || cls.includes('bg-accent-region')
}

/**
 * Check if element appears to be being dragged (uses data-dragging attribute)
 */
export function isVisuallyDragging(element: HTMLElement): boolean {
  // First check data attribute (preferred)
  if (element.hasAttribute('data-dragging')) {
    return true
  }
  // Fallback: class-based check
  return element.className.includes('z-20')
}

/**
 * Check if element shows pending state (uses data-pending attribute)
 */
export function isVisuallyPending(element: HTMLElement): boolean {
  // First check data attribute (preferred)
  if (element.hasAttribute('data-pending') || element.hasAttribute('data-new')) {
    return true
  }
  // Fallback: class-based check
  const cls = element.className
  return cls.includes('ring-amber') || cls.includes('ring-white')
}

/**
 * Check if element is a new (unsaved) region (uses data-new attribute)
 */
export function isVisuallyNew(element: HTMLElement): boolean {
  // First check data attribute (preferred)
  if (element.hasAttribute('data-new')) {
    return true
  }
  // Fallback: class-based check
  return element.className.includes('ring-white')
}

// ============================================================================
// Position Queries
// ============================================================================

/**
 * Get element's position as percentages (from style)
 */
export function getPositionPercent(element: HTMLElement): { left: number; width: number } {
  return {
    left: parseFloat(element.style.left) || 0,
    width: parseFloat(element.style.width) || 0,
  }
}

/**
 * Get element's bounding box (for gesture simulation)
 */
export function getBounds(element: HTMLElement): DOMRect {
  return element.getBoundingClientRect()
}

/**
 * Get center point of element
 */
export function getCenter(element: HTMLElement): { x: number; y: number } {
  const rect = element.getBoundingClientRect()
  return {
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
  }
}

/**
 * Get left edge point of element (for resize-start)
 */
export function getLeftEdge(element: HTMLElement): { x: number; y: number } {
  const rect = element.getBoundingClientRect()
  return {
    x: rect.left + 5, // Just inside the edge
    y: rect.top + rect.height / 2,
  }
}

/**
 * Get right edge point of element (for resize-end)
 */
export function getRightEdge(element: HTMLElement): { x: number; y: number } {
  const rect = element.getBoundingClientRect()
  return {
    x: rect.right - 5, // Just inside the edge
    y: rect.top + rect.height / 2,
  }
}

// ============================================================================
// Assertion Helpers
// ============================================================================

/**
 * Get a snapshot of visible region states
 */
export function getRegionStates(container: HTMLElement): Array<{
  name: string
  selected: boolean
  pending: boolean
  left: number
  width: number
}> {
  const regions = findAllRegionElements(container)
  return regions.map(el => {
    const nameSpan = el.querySelector('span')
    return {
      name: nameSpan?.textContent?.trim() || 'unknown',
      selected: isVisuallySelected(el),
      pending: isVisuallyPending(el),
      ...getPositionPercent(el),
    }
  })
}

/**
 * Find the time selection element
 */
export function findTimeSelection(container: HTMLElement): HTMLElement | null {
  return container.querySelector('[data-testid="time-selection"]')
}

/**
 * Find the selection preview element (during drag)
 */
export function findSelectionPreview(container: HTMLElement): HTMLElement | null {
  return container.querySelector('[data-testid="selection-preview"]')
}

/**
 * Find the insertion indicator element
 */
export function findInsertionIndicator(container: HTMLElement): HTMLElement | null {
  return container.querySelector('[data-testid="insertion-indicator"]')
}

/**
 * Check if an insertion point indicator is visible
 */
export function hasInsertionIndicator(container: HTMLElement): boolean {
  // First check data-testid (preferred)
  if (container.querySelector('[data-testid="insertion-indicator"]')) {
    return true
  }
  // Fallback: Look for the insertion indicator line (semantic token)
  return container.querySelector('.bg-insert-indicator') !== null
}

/**
 * Check if resize edge indicator is visible
 */
export function hasResizeIndicator(container: HTMLElement): boolean {
  // First check data-testid (preferred)
  if (container.querySelector('[data-testid="resize-indicator"]')) {
    return true
  }
  // Fallback: Similar to insertion but during resize operations
  const indicator = container.querySelector('[class*="bg-insert-indicator"]')
  return indicator !== null
}
