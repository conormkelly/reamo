/**
 * Time Display Component
 * Shows current playback position
 */

import type { ReactElement } from 'react';
import { useTransport } from '../../hooks/useTransport';
import { PlayStateLabel } from '../../core/types';

export interface TimeDisplayProps {
  className?: string;
  /** Show time format (default), beats format, or both */
  format?: 'time' | 'beats' | 'both';
  /** Show playback state label */
  showState?: boolean;
}

export function TimeDisplay({
  className = '',
  format = 'time',
  showState = false,
}: TimeDisplayProps): ReactElement {
  const { playState, positionString, positionBeats } = useTransport();

  const stateLabel = PlayStateLabel[playState];

  return (
    <div className={`font-mono ${className}`}>
      {showState && (
        <div className="text-xs uppercase text-gray-400 mb-1">{stateLabel}</div>
      )}
      <div className="text-2xl">
        {format === 'time' && positionString}
        {format === 'beats' && positionBeats}
        {format === 'both' && (
          <>
            <span>{positionString}</span>
            <span className="text-gray-500 mx-2">|</span>
            <span className="text-gray-400">{positionBeats}</span>
          </>
        )}
      </div>
    </div>
  );
}
