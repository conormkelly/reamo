/**
 * TransportTimeDisplay Component
 * Compact time/beats display for the landscape ViewHeader.
 *
 * Shows current transport position as beats (primary) and time (secondary).
 * Uses 60fps ref-based updates to avoid React re-renders.
 *
 * Gestures:
 * - Double-tap: opens QuickActionsPanel
 * - Long-press: opens MarkerNavigationPanel
 */

import { type ReactElement, useState, useCallback, useRef } from 'react';
import { useLongPress, useDoubleTap, useTransportAnimation } from '../../hooks';
import { formatTime } from '../../utils';
import { QuickActionsPanel } from './QuickActionsPanel';
import { MarkerNavigationPanel } from './MarkerNavigationPanel';

export function TransportTimeDisplay(): ReactElement {
  const [isQuickActionsOpen, setIsQuickActionsOpen] = useState(false);
  const [isMarkerNavOpen, setIsMarkerNavOpen] = useState(false);

  const beatsRef = useRef<HTMLSpanElement>(null);
  const timeRef = useRef<HTMLSpanElement>(null);

  useTransportAnimation((state) => {
    if (beatsRef.current) beatsRef.current.textContent = state.positionBeats;
    if (timeRef.current) timeRef.current.textContent = formatTime(state.position, { precision: 0 });
  }, []);

  const { onClick: handleDoubleTap } = useDoubleTap({
    onDoubleTap: useCallback(() => setIsQuickActionsOpen(true), []),
  });

  const { handlers: timeDisplayHandlers } = useLongPress({
    onTap: handleDoubleTap,
    onLongPress: useCallback(() => setIsMarkerNavOpen(true), []),
    duration: 500,
  });

  return (
    <>
      <button
        {...timeDisplayHandlers}
        className="flex flex-col items-center px-2 py-1 rounded-lg hover:bg-bg-hover active:bg-bg-elevated transition-colors touch-none"
        title="Double-tap: quick actions, Hold: markers"
        aria-label="Time display. Double-tap for quick actions, hold for marker navigation"
      >
        <span ref={beatsRef} className="text-xs font-mono text-text-primary leading-tight">1.1.00</span>
        <span ref={timeRef} className="text-[10px] font-mono text-text-muted leading-tight">0:00</span>
      </button>

      <QuickActionsPanel
        isOpen={isQuickActionsOpen}
        onClose={() => setIsQuickActionsOpen(false)}
      />
      <MarkerNavigationPanel
        isOpen={isMarkerNavOpen}
        onClose={() => setIsMarkerNavOpen(false)}
      />
    </>
  );
}
