/**
 * Level Meter Component
 * Displays real-time audio level for a track
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { volumeToDb, clampDb } from '../../utils/volume';

export interface LevelMeterProps {
  trackIndex: number;
  className?: string;
  /** Height in pixels (default: 100) */
  height?: number;
  /** Minimum dB to display (default: -60) */
  minDb?: number;
  /** Maximum dB to display (default: 6) */
  maxDb?: number;
  /** Show peak hold indicator */
  showPeak?: boolean;
  /** Orientation */
  orientation?: 'vertical' | 'horizontal';
}

export function LevelMeter({
  trackIndex,
  className = '',
  height = 100,
  minDb = -60,
  maxDb = 6,
  showPeak = true,
  orientation = 'vertical',
}: LevelMeterProps): ReactElement {
  const { track } = useTrack(trackIndex);

  // Get meter values (WebSocket sends linear amplitude: 1.0 = 0dB)
  const peakDb = track ? volumeToDb(track.lastMeterPeak) : -Infinity;
  const posDb = track ? volumeToDb(track.lastMeterPos) : -Infinity;

  // Calculate percentages
  const dbRange = maxDb - minDb;
  const peakPercent = Math.max(0, Math.min(100, ((clampDb(peakDb, minDb, maxDb) - minDb) / dbRange) * 100));
  const posPercent = Math.max(0, Math.min(100, ((clampDb(posDb, minDb, maxDb) - minDb) / dbRange) * 100));

  // Determine color based on level
  const getColor = (percent: number): string => {
    if (percent > 95) return 'bg-red-500'; // Clipping
    if (percent > 80) return 'bg-yellow-500'; // Hot
    if (percent > 50) return 'bg-green-500'; // Good
    return 'bg-green-600'; // Low
  };

  const isVertical = orientation === 'vertical';

  return (
    <div
      className={`relative bg-gray-900 rounded overflow-hidden ${className}`}
      style={isVertical ? { width: 12, height } : { height: 12, width: height }}
    >
      {/* Background gradient markers */}
      <div className="absolute inset-0 flex flex-col justify-between opacity-20">
        <div className="h-px bg-red-500" style={{ marginTop: '5%' }} />
        <div className="h-px bg-yellow-500" style={{ marginTop: '15%' }} />
        <div className="h-px bg-gray-500" style={{ marginTop: '50%' }} />
      </div>

      {/* Current level (RMS/position) */}
      <div
        className={`absolute ${getColor(posPercent)} transition-all duration-75 ${
          isVertical ? 'bottom-0 left-0 right-0' : 'left-0 top-0 bottom-0'
        }`}
        style={
          isVertical
            ? { height: `${posPercent}%` }
            : { width: `${posPercent}%` }
        }
      />

      {/* Peak indicator */}
      {showPeak && peakPercent > 0 && (
        <div
          className={`absolute bg-white ${
            isVertical ? 'left-0 right-0 h-0.5' : 'top-0 bottom-0 w-0.5'
          }`}
          style={
            isVertical
              ? { bottom: `${peakPercent}%` }
              : { left: `${peakPercent}%` }
          }
        />
      )}

      {/* Clip indicator - uses sticky flag from extension (cleared via meter/clearClip) */}
      {track?.clipped && (
        <div
          className={`absolute bg-red-500 animate-pulse ${
            isVertical ? 'top-0 left-0 right-0 h-2' : 'right-0 top-0 bottom-0 w-2'
          }`}
        />
      )}
    </div>
  );
}
