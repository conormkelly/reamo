/**
 * FX Parameter Subscription Hook
 * Subscribes to the values of the FX parameters around the rows on screen,
 * moving the subscription as the list scrolls.
 *
 * The extension pushes values only for subscribed parameters, at most
 * MAX_SUBSCRIBED_PARAMS of them, so a plugin with hundreds of parameters is
 * paged through: the subscription covers the visible rows plus a buffer on
 * each side, and moves only when the visible rows come near its edge.
 *
 * @example
 * ```tsx
 * const virtualizer = useVirtualizer({ ... });
 * virtualizer.getVirtualItems();
 * useFxParamSubscription({
 *   enabled: isOpen,
 *   trackGuid,
 *   fxGuid,
 *   paramIndices: filteredParams.map((p) => p.idx),
 *   visibleRange: virtualizer.range,
 *   sendCommand,
 * });
 * ```
 */

import { useEffect, useRef } from 'react';
import { useReaperStore } from '../store';
import { trackFxParams, type WSCommand } from '../core/WebSocketCommands';

/**
 * Most parameters one subscription may cover. The extension rejects a
 * request for more (MAX_SUBSCRIBED_PARAMS in trackfxparam_subscriptions.zig)
 * with TOO_MANY_PARAMS and keeps the previous subscription, so a larger
 * window would leave the list showing the old window's values.
 */
export const MAX_SUBSCRIBED_PARAMS = 100;

/**
 * The window moves once the visible rows come within this many rows of an
 * edge of it (an edge at the end of the list never needs a margin). It is
 * the headroom for a fast fling, about 55 rows/s: a move takes up to
 * SUBSCRIBE_THROTTLE_MS plus a round trip and a 33 ms poll tick, about
 * 200 ms or 11 rows, before its values arrive, so 15 rows lets the new
 * values land before the visible rows leave the old window. With the
 * buffer at ~47 rows a side, the window moves once per ~32 rows scrolled.
 */
export const RECENTER_MARGIN = 15;

/** Minimum time between two subscribe messages while scrolling. */
export const SUBSCRIBE_THROTTLE_MS = 100;

/**
 * Rows subscribed beyond each end of `visibleCount` visible rows: the rest
 * of the MAX_SUBSCRIBED_PARAMS budget, split evenly.
 */
export function bufferFor(visibleCount: number): number {
  return Math.max(0, Math.floor((MAX_SUBSCRIBED_PARAMS - visibleCount) / 2));
}

/** Inclusive range of list positions. */
export interface ListWindow {
  start: number;
  end: number;
}

/**
 * The list positions to subscribe to, given the rows on screen.
 *
 * Keeps `current` while the visible rows sit inside it with RECENTER_MARGIN
 * to spare, so small scrolls send nothing. Otherwise centres a new window on
 * the visible rows, bufferFor(visible rows) each side, and spends the whole
 * budget: the window is min(MAX_SUBSCRIBED_PARAMS, list length) rows, never
 * more, shifted inward near an end of the list rather than cut short.
 *
 * @param current - The window subscribed now, or null for none
 * @param visible - First and last list positions on screen
 * @param count - Number of rows in the list
 * @returns The window to subscribe to, or null for an empty list
 */
export function nextSubscriptionWindow(
  current: ListWindow | null,
  visible: ListWindow,
  count: number
): ListWindow | null {
  if (count <= 0) return null;

  const visibleStart = Math.min(Math.max(0, visible.start), count - 1);
  const visibleEnd = Math.min(Math.max(visibleStart, visible.end), count - 1);
  const visibleCount = visibleEnd - visibleStart + 1;

  if (visibleCount >= MAX_SUBSCRIBED_PARAMS) {
    return { start: visibleStart, end: visibleStart + MAX_SUBSCRIBED_PARAMS - 1 };
  }

  const buffer = bufferFor(visibleCount);

  if (current && current.start >= 0 && current.end < count && current.start <= current.end) {
    const margin = Math.min(RECENTER_MARGIN, buffer);
    const clearOfStart = current.start === 0 || visibleStart >= current.start + margin;
    const clearOfEnd = current.end === count - 1 || visibleEnd <= current.end - margin;
    if (visibleStart >= current.start && visibleEnd <= current.end && clearOfStart && clearOfEnd) {
      return current;
    }
  }

  // Near an end of the list, shift the window inward so it keeps its size:
  // the rows cut off at one end are spent at the other
  const size = Math.min(MAX_SUBSCRIBED_PARAMS, count);
  const start = Math.min(Math.max(0, visibleStart - buffer), count - size);
  return { start, end: start + size - 1 };
}

export interface UseFxParamSubscriptionOptions {
  /** Whether to subscribe (the parameter list is open and its skeleton loaded) */
  enabled: boolean;
  trackGuid: string;
  fxGuid: string;
  /** Parameter index of each list row, in list order */
  paramIndices: readonly number[];
  /** First and last list positions on screen, or null before the list is laid out */
  visibleRange: { startIndex: number; endIndex: number } | null;
  /** Function to send commands */
  sendCommand: (cmd: WSCommand) => void;
}

/**
 * Subscribe to the parameters around the visible rows of an FX's parameter
 * list, in indices mode.
 *
 * Indices mode serves both the full list and a filtered one (whose rows are
 * scattered parameters) with one request shape, and the extension enforces
 * its limit on it. Lists are compared by content: an equal list (a
 * refetched skeleton with the same names) keeps the window. A list with
 * different content (a filter or a changed skeleton) is taken to be shown
 * from its top, and the caller must scroll it there: its window is worked
 * out for the rows that fit at the top, not from the visible range of the
 * render that brought it (still the old scroll position), and sent at once.
 * Scrolling moves are throttled to one per SUBSCRIBE_THROTTLE_MS, always
 * ending on the latest window, and the current window is sent again when
 * the connection comes back. Unsubscribing is the caller's job: it owns the
 * subscription's lifetime.
 */
export function useFxParamSubscription(options: UseFxParamSubscriptionOptions): void {
  const { enabled, trackGuid, fxGuid, paramIndices, visibleRange, sendCommand } = options;

  const connected = useReaperStore((state) => state.connected);

  const windowRef = useRef<ListWindow | null>(null);
  const listRef = useRef<readonly number[] | null>(null);
  const lastSentKeyRef = useRef<string | null>(null);
  const lastSentAtRef = useRef(0);
  const wasConnectedRef = useRef(connected);

  const visibleStart = visibleRange?.startIndex ?? null;
  const visibleEnd = visibleRange?.endIndex ?? null;

  useEffect(() => {
    const justConnected = connected && !wasConnectedRef.current;
    wasConnectedRef.current = connected;

    if (!enabled || !connected) {
      windowRef.current = null;
      lastSentKeyRef.current = null;
      return;
    }
    if (visibleStart === null || visibleEnd === null) return;

    const newList = listRef.current !== null && !sameList(listRef.current, paramIndices);
    listRef.current = paramIndices;
    if (newList) windowRef.current = null;

    const visible = newList
      ? { start: 0, end: visibleEnd - visibleStart }
      : { start: visibleStart, end: visibleEnd };
    const next = nextSubscriptionWindow(windowRef.current, visible, paramIndices.length);
    if (!next) return;
    windowRef.current = next;

    const indices = paramIndices.slice(next.start, next.end + 1);
    const key = `${trackGuid}|${fxGuid}|${indices.join(',')}`;
    if (key === lastSentKeyRef.current && !justConnected) return;

    const send = () => {
      lastSentAtRef.current = Date.now();
      lastSentKeyRef.current = key;
      sendCommand(trackFxParams.subscribe(trackGuid, fxGuid, { indices }));
    };

    const wait = SUBSCRIBE_THROTTLE_MS - (Date.now() - lastSentAtRef.current);
    if (justConnected || newList || wait <= 0) {
      send();
      return;
    }

    // A pending move is superseded by the next run of this effect (which
    // reschedules it against the same last send) or dropped on unmount
    const timer = setTimeout(send, wait);
    return () => clearTimeout(timer);
  }, [enabled, connected, trackGuid, fxGuid, paramIndices, visibleStart, visibleEnd, sendCommand]);
}

/** Whether two lists hold the same parameter indices in the same order. */
function sameList(a: readonly number[], b: readonly number[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}
