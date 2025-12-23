/**
 * useDoubleTap Hook
 * Detects double-tap/double-click gestures with configurable delay
 */

import { useCallback, useRef } from 'react';

export interface UseDoubleTapOptions {
  /** Callback for single tap (optional) */
  onSingleTap?: () => void;
  /** Callback for double tap */
  onDoubleTap: () => void;
  /** Max time between taps in ms (default: 300) */
  delay?: number;
}

export interface UseDoubleTapResult {
  /** Event handler to attach to onClick/onTouchEnd */
  onClick: () => void;
}

/**
 * Hook for detecting double-tap gestures
 *
 * @example
 * ```tsx
 * const { onClick } = useDoubleTap({
 *   onSingleTap: () => console.log('single'),
 *   onDoubleTap: () => console.log('double!'),
 *   delay: 300,
 * });
 *
 * return <button onClick={onClick}>Tap me</button>;
 * ```
 */
export function useDoubleTap({
  onSingleTap,
  onDoubleTap,
  delay = 300,
}: UseDoubleTapOptions): UseDoubleTapResult {
  const lastTapRef = useRef<number>(0);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const onClick = useCallback(() => {
    const now = Date.now();
    const timeSinceLastTap = now - lastTapRef.current;

    if (timeSinceLastTap < delay && timeSinceLastTap > 0) {
      // Double tap detected
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
        timeoutRef.current = null;
      }
      lastTapRef.current = 0;
      onDoubleTap();
    } else {
      // First tap - wait to see if there's a second
      lastTapRef.current = now;

      if (onSingleTap) {
        // Clear any existing timeout
        if (timeoutRef.current) {
          clearTimeout(timeoutRef.current);
        }
        // Set timeout for single tap callback
        timeoutRef.current = setTimeout(() => {
          onSingleTap();
          timeoutRef.current = null;
        }, delay);
      }
    }
  }, [onSingleTap, onDoubleTap, delay]);

  return { onClick };
}
