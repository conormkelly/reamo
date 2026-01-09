/**
 * Time Display Component
 * Shows current playback position with smooth 60fps updates
 *
 * Uses client-side interpolation via the TransportAnimationEngine
 * for smooth display updates without React re-render overhead.
 */

import { useRef, type ReactElement } from 'react';
import { Loader2 } from 'lucide-react';
import { useTransport } from '../../hooks/useTransport';
import { useTransportAnimation } from '../../hooks';
import { PlayStateLabel } from '../../core/types';
import { formatTime } from '../../utils';

export interface TimeDisplayProps {
  className?: string;
  /** Show time format (default), beats format, or both */
  format?: 'time' | 'beats' | 'both';
  /** Show playback state label */
  showState?: boolean;
  /** Whether time selection sync is in progress */
  isSyncing?: boolean;
}

export function TimeDisplay({
  className = '',
  format = 'time',
  showState = false,
  isSyncing = false,
}: TimeDisplayProps): ReactElement {
  const { playState } = useTransport();

  // Refs for direct DOM updates at 60fps
  const timeRef = useRef<HTMLSpanElement>(null);
  const beatsRef = useRef<HTMLSpanElement>(null);

  // Subscribe to 60fps animation updates
  useTransportAnimation((state) => {
    if (timeRef.current) {
      timeRef.current.textContent = formatTime(state.position, { precision: 3, showSign: true });
    }
    if (beatsRef.current) {
      beatsRef.current.textContent = state.positionBeats;
    }
  }, []);

  const stateLabel = PlayStateLabel[playState];

  return (
    <div data-testid="time-display" className={`font-mono ${className}`}>
      {showState && (
        <div className="text-xs uppercase text-text-secondary mb-1">{stateLabel}</div>
      )}
      <div className="text-2xl">
        {isSyncing ? (
          <Loader2 className="w-6 h-6 text-text-muted animate-spin inline-block" />
        ) : (
          <>
            {format === 'time' && <span ref={timeRef}>0:00.000</span>}
            {format === 'beats' && <span ref={beatsRef}>1.1.00</span>}
            {format === 'both' && (
              <>
                <span ref={beatsRef}>1.1.00</span>
                <span className="text-text-muted mx-2">|</span>
                <span ref={timeRef} className="text-text-secondary">0:00.000</span>
              </>
            )}
          </>
        )}
      </div>
    </div>
  );
}
