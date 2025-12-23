/**
 * Gesture Simulation Utilities
 *
 * Simulate pointer interactions for component testing.
 * These create realistic event sequences that match actual user behavior.
 */

import { fireEvent } from '@testing-library/react'

// ============================================================================
// Types
// ============================================================================

export interface Point {
  x: number
  y: number
}

// ============================================================================
// Core Event Helpers
// ============================================================================

function pointerEvent(
  type: 'pointerdown' | 'pointermove' | 'pointerup',
  point: Point,
  options?: Partial<PointerEventInit>
): PointerEventInit {
  return {
    pointerId: 1,
    clientX: point.x,
    clientY: point.y,
    button: 0,
    buttons: type === 'pointerup' ? 0 : 1,
    pointerType: 'touch',
    isPrimary: true,
    bubbles: true,
    ...options,
  }
}

// ============================================================================
// Gesture Simulators
// ============================================================================

/**
 * Simulate a tap (quick press and release)
 */
export function tap(element: Element, at: Point): void {
  fireEvent.pointerDown(element, pointerEvent('pointerdown', at))
  fireEvent.pointerUp(element, pointerEvent('pointerup', at))
}

/**
 * Simulate a drag from one point to another
 */
export function drag(
  element: Element,
  from: Point,
  to: Point,
  options?: { steps?: number }
): void {
  const steps = options?.steps ?? 10

  fireEvent.pointerDown(element, pointerEvent('pointerdown', from))

  // Intermediate move events
  for (let i = 1; i <= steps; i++) {
    const progress = i / steps
    const point = {
      x: from.x + (to.x - from.x) * progress,
      y: from.y + (to.y - from.y) * progress,
    }
    fireEvent.pointerMove(element, pointerEvent('pointermove', point))
  }

  fireEvent.pointerUp(element, pointerEvent('pointerup', to))
}

/**
 * Simulate a drag that gets cancelled (vertical movement)
 */
export function dragCancel(element: Element, from: Point, moveX: number): void {
  fireEvent.pointerDown(element, pointerEvent('pointerdown', from))

  // Move horizontally
  fireEvent.pointerMove(element, pointerEvent('pointermove', {
    x: from.x + moveX,
    y: from.y,
  }))

  // Move vertically to cancel (> 50px threshold)
  const cancelPoint = { x: from.x + moveX, y: from.y + 100 }
  fireEvent.pointerMove(element, pointerEvent('pointermove', cancelPoint))
  fireEvent.pointerUp(element, pointerEvent('pointerup', cancelPoint))
}

/**
 * Simulate a long press (async - waits for hold timer)
 */
export async function longPress(
  element: Element,
  at: Point,
  holdMs: number = 500
): Promise<void> {
  fireEvent.pointerDown(element, pointerEvent('pointerdown', at))
  await sleep(holdMs + 50)
  fireEvent.pointerUp(element, pointerEvent('pointerup', at))
}

/**
 * Simulate hold then drag (for time selection)
 */
export async function holdAndDrag(
  element: Element,
  from: Point,
  to: Point,
  holdMs: number = 300
): Promise<void> {
  fireEvent.pointerDown(element, pointerEvent('pointerdown', from))
  await sleep(holdMs + 50)
  fireEvent.pointerMove(element, pointerEvent('pointermove', to))
  fireEvent.pointerUp(element, pointerEvent('pointerup', to))
}

// ============================================================================
// Point Helpers
// ============================================================================

/**
 * Create a point
 */
export function point(x: number, y: number): Point {
  return { x, y }
}

/**
 * Calculate point at percentage of container width
 */
export function atPercent(
  container: DOMRect | { left: number; width: number; top: number; height: number },
  xPercent: number,
  yPercent: number = 50
): Point {
  return {
    x: container.left + (container.width * xPercent) / 100,
    y: container.top + (container.height * yPercent) / 100,
  }
}

/**
 * Offset a point
 */
export function offset(p: Point, dx: number, dy: number = 0): Point {
  return { x: p.x + dx, y: p.y + dy }
}

// ============================================================================
// Utilities
// ============================================================================

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/**
 * Wait for next tick (useful after state updates)
 */
export function nextTick(): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, 0))
}

/**
 * Advance fake timers (if using vi.useFakeTimers)
 */
export async function advanceTimers(ms: number): Promise<void> {
  const { vi } = await import('vitest')
  vi.advanceTimersByTime(ms)
  await nextTick()
}
