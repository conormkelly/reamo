/**
 * Time Display Component
 * Shows current playback position
 */

import type { ReactElement } from 'react';
import { useMemo } from 'react';
import { Loader2 } from 'lucide-react';
import { useTransport } from '../../hooks/useTransport';
import { PlayStateLabel } from '../../core/types';

/**
 * Format seconds as MM:SS.ms
 */
function formatTime(seconds: number): string {
  const absSeconds = Math.abs(seconds);
  const sign = seconds < 0 ? '-' : '';
  const mins = Math.floor(absSeconds / 60);
  const secs = Math.floor(absSeconds % 60);
  const ms = Math.floor((absSeconds % 1) * 1000);
  return `${sign}${mins}:${secs.toString().padStart(2, '0')}.${ms.toString().padStart(3, '0')}`;
}

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
  const { playState, positionSeconds, positionBeats } = useTransport();

  const stateLabel = PlayStateLabel[playState];
  const timeString = useMemo(() => formatTime(positionSeconds), [positionSeconds]);

  return (
    <div className={`font-mono ${className}`}>
      {showState && (
        <div className="text-xs uppercase text-gray-400 mb-1">{stateLabel}</div>
      )}
      <div className="text-2xl">
        {isSyncing ? (
          <Loader2 className="w-6 h-6 text-gray-500 animate-spin inline-block" />
        ) : (
          <>
            {format === 'time' && timeString}
            {format === 'beats' && positionBeats}
            {format === 'both' && (
              <>
                <span>{timeString}</span>
                <span className="text-gray-500 mx-2">|</span>
                <span className="text-gray-400">{positionBeats}</span>
              </>
            )}
          </>
        )}
      </div>
    </div>
  );
}
