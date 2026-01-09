/**
 * DOM Query Utilities
 *
 * Helpers for finding and inspecting elements in rendered components.
 * Focused on semantic queries - what the user sees, not implementation.
 */

// ============================================================================
// Element Finders
// ============================================================================

/**
 * Find a region element by its name
 */
export function findRegionElement(container: HTMLElement, name: string): HTMLElement | null {
  // Regions display their name in a span
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
 * Find all region elements
 */
export function findAllRegionElements(container: HTMLElement): HTMLElement[] {
  // Regions have position styling (left%, width%)
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
 * Check if element appears selected (purple border/bg)
 */
export function isVisuallySelected(element: HTMLElement): boolean {
  const cls = element.className
  return cls.includes('border-purple') || cls.includes('bg-purple')
}

/**
 * Check if element appears to be being dragged (elevated z-index)
 */
export function isVisuallyDragging(element: HTMLElement): boolean {
  return element.className.includes('z-20')
}

/**
 * Check if element shows pending state (ring indicator)
 */
export function isVisuallyPending(element: HTMLElement): boolean {
  const cls = element.className
  return cls.includes('ring-amber') || cls.includes('ring-white')
}

/**
 * Check if element is a new (unsaved) region
 */
export function isVisuallyNew(element: HTMLElement): boolean {
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
 * Check if an insertion point indicator is visible
 */
export function hasInsertionIndicator(container: HTMLElement): boolean {
  // Look for the insertion indicator line (semantic token)
  return container.querySelector('.bg-insert-indicator') !== null
}

/**
 * Check if resize edge indicator is visible
 */
export function hasResizeIndicator(container: HTMLElement): boolean {
  // Similar to insertion but during resize operations
  const indicator = container.querySelector('[class*="bg-insert-indicator"]')
  return indicator !== null
}
