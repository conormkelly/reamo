/**
 * useLongPress Hook
 * Detects long-press gestures with configurable duration
 */

import { useCallback, useRef } from 'react';

export interface UseLongPressOptions {
  /** Callback when long press is detected */
  onLongPress: () => void;
  /** Duration in ms before long press triggers (default: 300) */
  duration?: number;
}

export interface UseLongPressResult {
  /** Event handlers to spread onto the element */
  handlers: {
    onMouseDown: (e: React.MouseEvent) => void;
    onMouseUp: () => void;
    onMouseLeave: () => void;
    onTouchStart: (e: React.TouchEvent) => void;
    onTouchEnd: () => void;
  };
}

/**
 * Hook for detecting long-press gestures
 *
 * @example
 * ```tsx
 * const { handlers } = useLongPress({
 *   onLongPress: () => console.log('long pressed!'),
 *   duration: 300,
 * });
 *
 * return <div {...handlers}>Hold me</div>;
 * ```
 */
export function useLongPress({
  onLongPress,
  duration = 300,
}: UseLongPressOptions): UseLongPressResult {
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const triggeredRef = useRef(false);

  const start = useCallback(() => {
    triggeredRef.current = false;
    timeoutRef.current = setTimeout(() => {
      triggeredRef.current = true;
      onLongPress();
    }, duration);
  }, [onLongPress, duration]);

  const clear = useCallback(() => {
    if (timeoutRef.current) {
      clearTimeout(timeoutRef.current);
      timeoutRef.current = null;
    }
  }, []);

  const onMouseDown = useCallback(
    (e: React.MouseEvent) => {
      // Prevent text selection during long press
      e.preventDefault();
      start();
    },
    [start]
  );

  const onTouchStart = useCallback(
    (e: React.TouchEvent) => {
      // Prevent default to avoid scroll/zoom during long press
      e.preventDefault();
      start();
    },
    [start]
  );

  return {
    handlers: {
      onMouseDown,
      onMouseUp: clear,
      onMouseLeave: clear,
      onTouchStart,
      onTouchEnd: clear,
    },
  };
}
