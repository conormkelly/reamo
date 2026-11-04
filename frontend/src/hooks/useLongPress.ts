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
 * leaves the element, when the mouse's primary button is no longer down, when
 * a mouse opens the context menu, when another press begins, when the window
 * loses focus or the page is hidden (another app, or a locked phone, now has
 * the pointer), or when the element unmounts. A touch or pen held still also
 * raises a context menu event, on Android at about the long press's own
 * duration; that one is suppressed and the hold goes on. A right-button press
 * is neither, and nor is a mouse Ctrl+click on any platform, as on macOS it
 * opens the context menu.
 *
 * A click with no pointer press behind it (Enter or Space on a focused button,
 * or a screen reader's activation) is a tap. A held key is one tap: the
 * browser clicks a focused button on every Enter keydown, its auto-repeats
 * included, so the key repeats of Enter and Space on the element are
 * cancelled, which cancels their clicks. Holding a key never long-presses.
 *
 * Pressing the element doesn't take focus, so a text field being typed in
 * keeps it and a phone's keyboard stays up. With `takeFocus` it does, as a
 * button press does by default, and the element is focused before the tap or
 * long press runs: a field being edited elsewhere blurs, and commits, before
 * the element acts. A finger's emulated mousedown, which would focus it, comes
 * only after the release that taps.
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from 'react';

export interface UseLongPressOptions {
  /** Called when a press is released before it becomes a long press */
  onTap?: () => void;
  /** Called when a press is held still for `duration` */
  onLongPress?: () => void;
  /** Duration in ms before long press triggers (default: 400) */
  duration?: number;
  /** Pressing the element focuses it, before the tap or long press runs (default: false) */
  takeFocus?: boolean;
}

export interface UseLongPressResult {
  /** Event handlers to spread onto the element */
  handlers: {
    onPointerDown: (e: React.PointerEvent) => void;
    onPointerMove: (e: React.PointerEvent) => void;
    onPointerUp: (e: React.PointerEvent) => void;
    onPointerCancel: (e: React.PointerEvent) => void;
    onPointerLeave: (e: React.PointerEvent) => void;
    onMouseDown: (e: React.MouseEvent) => void;
    onContextMenu: (e: React.MouseEvent) => void;
    onClick: (e: React.MouseEvent) => void;
    onKeyDown: (e: React.KeyboardEvent) => void;
  };
}

/** How far, in CSS px, a press may drift and still count as holding still. */
const LONG_PRESS_MOVE_TOLERANCE = 10;

/** How long after a pointer's tap a click with no detail is taken for its own. */
const CLICK_AFTER_TAP_MS = 500;

interface Press {
  /** The element pressed. */
  el: HTMLElement;
  pointerId: number;
  x: number;
  y: number;
  /** A mouse press began with its primary button reported down. */
  primaryDown: boolean;
  timer: ReturnType<typeof setTimeout> | null;
  /** Stops listening for the window losing focus or the page being hidden. */
  unlisten: () => void;
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
  takeFocus = false,
}: UseLongPressOptions): UseLongPressResult {
  // The press under way; null when there is none, or once it has ended in a
  // long press or been cancelled.
  const pressRef = useRef<Press | null>(null);
  // When a pointer release last tapped, so the click that follows the
  // release is not a second tap.
  const pointerTappedAtRef = useRef<number | null>(null);
  // The type of the latest press's pointer, kept after the press ends: a
  // touch's context menu event can come after its long press has fired.
  const pointerTypeRef = useRef<string | null>(null);

  // The callbacks of the latest render: they read state, such as the mixer
  // lock, that can change while a press is held.
  const latest = useRef({ onTap, onLongPress, duration, takeFocus });
  useLayoutEffect(() => {
    latest.current = { onTap, onLongPress, duration, takeFocus };
  });

  // A field being edited elsewhere blurs, and commits, before the press acts.
  const focusIfTaking = useCallback((el: HTMLElement) => {
    if (latest.current.takeFocus) el.focus({ preventScroll: true });
  }, []);

  const cancel = useCallback(() => {
    const press = pressRef.current;
    if (!press) return;
    if (press.timer) clearTimeout(press.timer);
    press.unlisten();
    pressRef.current = null;
  }, []);

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      // Each press starts afresh.
      cancel();
      pointerTappedAtRef.current = null;
      pointerTypeRef.current = e.pointerType;
      const opensMenu = e.button !== 0 || (e.ctrlKey && e.pointerType === 'mouse');
      if (opensMenu) return;

      // The window losing focus or the page being hidden can come mid-press
      // with no pointer event to end it: the release goes to another app.
      // The listeners live only as long as the press, so they end this one.
      const onBlur = cancel;
      const onVisibilityChange = () => {
        if (document.visibilityState === 'hidden') cancel();
      };
      window.addEventListener('blur', onBlur);
      document.addEventListener('visibilitychange', onVisibilityChange);

      const press: Press = {
        el: e.currentTarget as HTMLElement,
        pointerId: e.pointerId,
        x: e.clientX,
        y: e.clientY,
        primaryDown: (e.buttons & 1) !== 0,
        timer: null,
        unlisten: () => {
          window.removeEventListener('blur', onBlur);
          document.removeEventListener('visibilitychange', onVisibilityChange);
        },
      };
      if (latest.current.onLongPress) {
        press.timer = setTimeout(() => {
          if (pressRef.current !== press) return;
          cancel();
          focusIfTaking(press.el);
          latest.current.onLongPress?.();
        }, latest.current.duration);
      }
      pressRef.current = press;
    },
    [cancel, focusIfTaking]
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      const press = pressRef.current;
      if (!press || e.pointerId !== press.pointerId) return;
      // A mouse whose primary button came up while another stays down sends
      // a move, not an up. A press that never reported its button down (a
      // screen reader's emulated pointer can) is left to the other checks.
      if (e.pointerType === 'mouse' && press.primaryDown && (e.buttons & 1) === 0) {
        cancel();
        return;
      }
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
      pointerTappedAtRef.current = Date.now();
      focusIfTaking(press.el);
      latest.current.onTap?.();
    },
    [cancel, focusIfTaking]
  );

  const onPointerEnd = useCallback(
    (e: React.PointerEvent) => {
      if (pressRef.current?.pointerId === e.pointerId) cancel();
    },
    [cancel]
  );

  // A pointer press drives the gesture; a click carries no pointer
  // (detail 0) only when a keyboard or a screen reader activated the element.
  // A click with no detail within CLICK_AFTER_TAP_MS of a pointer's tap
  // belongs to that tap; a later one is a keyboard's or a screen reader's.
  const onClick = useCallback((e: React.MouseEvent) => {
    const tappedAt = pointerTappedAtRef.current;
    pointerTappedAtRef.current = null;
    if (e.detail !== 0) return;
    if (tappedAt !== null && Date.now() - tappedAt < CLICK_AFTER_TAP_MS) return;
    latest.current.onTap?.();
  }, []);

  const onContextMenu = useCallback(
    (e: React.MouseEvent) => {
      if (pointerTypeRef.current === 'touch' || pointerTypeRef.current === 'pen') {
        e.preventDefault();
        return;
      }
      cancel();
    },
    [cancel]
  );

  const onMouseDown = useCallback((e: React.MouseEvent) => {
    if (!latest.current.takeFocus) e.preventDefault();
  }, []);

  // Only the element's own keys: a field inside it keeps its key repeats.
  const onKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.target !== e.currentTarget) return;
    if (e.repeat && (e.key === 'Enter' || e.key === ' ')) e.preventDefault();
  }, []);

  // A hold still running when the element leaves the page is abandoned.
  useEffect(() => cancel, [cancel]);

  const handlers = useMemo(
    () => ({
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel: onPointerEnd,
      onPointerLeave: onPointerEnd,
      onMouseDown,
      onContextMenu,
      onClick,
      onKeyDown,
    }),
    [onPointerDown, onPointerMove, onPointerUp, onPointerEnd, onMouseDown, onContextMenu, onClick, onKeyDown]
  );

  return { handlers };
}
