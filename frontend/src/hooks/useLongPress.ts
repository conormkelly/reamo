/**
 * useLongPress Hook
 * Detects tap and long-press gestures with configurable duration
 */

import { useCallback, useRef } from 'react';

export interface UseLongPressOptions {
  /** Callback when tap (short press) is detected */
  onTap?: () => void;
  /** Callback when long press is detected */
  onLongPress?: () => void;
  /** Duration in ms before long press triggers (default: 400) */
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
 * Hook for detecting tap and long-press gestures
 *
 * @example
 * ```tsx
 * const { handlers } = useLongPress({
 *   onTap: () => console.log('tapped!'),
 *   onLongPress: () => console.log('long pressed!'),
 *   duration: 400,
 * });
 *
 * return <div {...handlers}>Tap or hold me</div>;
 * ```
 */
export function useLongPress({
  onTap,
  onLongPress,
  duration = 400,
}: UseLongPressOptions): UseLongPressResult {
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const longPressTriggeredRef = useRef(false);
  const isTouchRef = useRef(false);

  const start = useCallback(
    (isTouch: boolean) => {
      // If this is a mouse event but we just had a touch, ignore it
      // (synthesized mouse events come after touch events)
      if (!isTouch && isTouchRef.current) return;

      isTouchRef.current = isTouch;
      longPressTriggeredRef.current = false;

      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }

      if (onLongPress) {
        timeoutRef.current = setTimeout(() => {
          longPressTriggeredRef.current = true;
          onLongPress();
        }, duration);
      }
    },
    [onLongPress, duration]
  );

  const end = useCallback(
    (isTouch: boolean) => {
      // Ignore mouse events if we're in a touch interaction
      if (!isTouch && isTouchRef.current) return;

      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
        timeoutRef.current = null;
      }

      // If long press didn't trigger, it's a tap
      if (!longPressTriggeredRef.current && onTap) {
        onTap();
      }

      // Reset touch flag after a delay to block synthesized mouse events
      if (isTouch) {
        setTimeout(() => {
          isTouchRef.current = false;
        }, 300);
      }
    },
    [onTap]
  );

  const cancel = useCallback(() => {
    if (timeoutRef.current) {
      clearTimeout(timeoutRef.current);
      timeoutRef.current = null;
    }
    longPressTriggeredRef.current = false;
    isTouchRef.current = false;
  }, []);

  const onMouseDown = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      start(false);
    },
    [start]
  );

  const onMouseUp = useCallback(() => {
    end(false);
  }, [end]);

  const onTouchStart = useCallback(
    (e: React.TouchEvent) => {
      e.preventDefault();
      start(true);
    },
    [start]
  );

  const onTouchEnd = useCallback(() => {
    end(true);
  }, [end]);

  return {
    handlers: {
      onMouseDown,
      onMouseUp,
      onMouseLeave: cancel,
      onTouchStart,
      onTouchEnd,
    },
  };
}
