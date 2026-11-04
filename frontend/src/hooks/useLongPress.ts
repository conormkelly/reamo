/**
 * useLongPress Hook
 * Tells a tap from a long press, for mouse, touch and pen alike.
 *
 * Only pointer events drive it: they report each press once, where the mouse
 * events a browser emulates after a touch would report it a second time.
 *
 * A press is a tap when it is released before the long press fires, and a
 * long press when it is held still for `duration`. Either way it counts only
 * while the pointer stays put: a press ends with neither when the pointer
 * moves more than a few pixels (a scroll or drag, not a hold), when the
 * browser cancels it (it took the touch over for a scroll), when the pointer
 * leaves the element, when another press begins, or when the element unmounts.
 * A right-button press, or a mouse Ctrl+click on macOS, opens the context
 * menu, so it is neither.
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from 'react';

export interface UseLongPressOptions {
  /** Called when a press is released before it becomes a long press */
  onTap?: () => void;
  /** Called when a press is held still for `duration` */
  onLongPress?: () => void;
  /** Duration in ms before long press triggers (default: 400) */
  duration?: number;
}

export interface UseLongPressResult {
  /** Event handlers to spread onto the element */
  handlers: {
    onPointerDown: (e: React.PointerEvent) => void;
    onPointerMove: (e: React.PointerEvent) => void;
    onPointerUp: (e: React.PointerEvent) => void;
    onPointerCancel: (e: React.PointerEvent) => void;
    onPointerLeave: (e: React.PointerEvent) => void;
  };
}

/** How far, in CSS px, a press may drift and still count as holding still. */
const LONG_PRESS_MOVE_TOLERANCE = 10;

interface Press {
  pointerId: number;
  x: number;
  y: number;
  timer: ReturnType<typeof setTimeout> | null;
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
  // The press under way; null when there is none, or once it has ended in a
  // long press or been cancelled.
  const pressRef = useRef<Press | null>(null);

  // The callbacks of the latest render: they read state, such as the mixer
  // lock, that can change while a press is held.
  const latest = useRef({ onTap, onLongPress, duration });
  useLayoutEffect(() => {
    latest.current = { onTap, onLongPress, duration };
  });

  const cancel = useCallback(() => {
    const press = pressRef.current;
    if (press?.timer) clearTimeout(press.timer);
    pressRef.current = null;
  }, []);

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      // Each press starts afresh.
      cancel();
      const opensMenu = e.button !== 0 || (e.ctrlKey && e.pointerType === 'mouse');
      if (opensMenu) return;

      const press: Press = { pointerId: e.pointerId, x: e.clientX, y: e.clientY, timer: null };
      if (latest.current.onLongPress) {
        press.timer = setTimeout(() => {
          if (pressRef.current !== press) return;
          pressRef.current = null;
          latest.current.onLongPress?.();
        }, latest.current.duration);
      }
      pressRef.current = press;
    },
    [cancel]
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      const press = pressRef.current;
      if (!press || e.pointerId !== press.pointerId) return;
      if (Math.hypot(e.clientX - press.x, e.clientY - press.y) > LONG_PRESS_MOVE_TOLERANCE) {
        cancel();
      }
    },
    [cancel]
  );

  const onPointerUp = useCallback(
    (e: React.PointerEvent) => {
      const press = pressRef.current;
      if (!press || e.pointerId !== press.pointerId) return;
      cancel();
      // A release can move the pointer without a pointermove before it.
      if (Math.hypot(e.clientX - press.x, e.clientY - press.y) > LONG_PRESS_MOVE_TOLERANCE) return;
      latest.current.onTap?.();
    },
    [cancel]
  );

  const onPointerEnd = useCallback(
    (e: React.PointerEvent) => {
      if (pressRef.current?.pointerId === e.pointerId) cancel();
    },
    [cancel]
  );

  // A hold still running when the element leaves the page is abandoned.
  useEffect(() => cancel, [cancel]);

  const handlers = useMemo(
    () => ({
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel: onPointerEnd,
      onPointerLeave: onPointerEnd,
    }),
    [onPointerDown, onPointerMove, onPointerUp, onPointerEnd]
  );

  return { handlers };
}
