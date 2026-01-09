/**
 * Level Meter Component
 * Displays real-time audio level for a track
 * Tap clip indicator to clear
 */

import { useState, useEffect, type ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { usePeakHold } from '../../hooks/usePeakHold';
import { useReaper } from '../ReaperProvider';
import { meter } from '../../core/WebSocketCommands';
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
  /** How long to hold peak indicator in ms (default: 1000) */
  peakHoldMs?: number;
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
  peakHoldMs = 1000,
  orientation = 'vertical',
}: LevelMeterProps): ReactElement {
  const { track } = useTrack(trackIndex);
  const { sendCommand } = useReaper();
  const [hasMounted, setHasMounted] = useState(false);

  // Enable transitions only after first render to prevent blip on remount
  useEffect(() => {
    const timer = setTimeout(() => setHasMounted(true), 50);
    return () => clearTimeout(timer);
  }, []);

  // Get meter values (WebSocket sends linear amplitude: 1.0 = 0dB)
  const peakDb = track ? volumeToDb(track.lastMeterPeak) : -Infinity;
  const posDb = track ? volumeToDb(track.lastMeterPos) : -Infinity;

  // Apply peak hold - keeps the peak indicator visible for peakHoldMs after signal drops
  const heldPeakDb = usePeakHold(peakDb, peakHoldMs);

  // Calculate percentages
  const dbRange = maxDb - minDb;
  const peakPercent = Math.max(0, Math.min(100, ((clampDb(heldPeakDb, minDb, maxDb) - minDb) / dbRange) * 100));
  const posPercent = Math.max(0, Math.min(100, ((clampDb(posDb, minDb, maxDb) - minDb) / dbRange) * 100));

  // Determine color based on level
  const getColor = (percent: number): string => {
    if (percent > 95) return 'bg-meter-clip'; // Clipping
    if (percent > 80) return 'bg-meter-hot'; // Hot
    if (percent > 50) return 'bg-meter-good'; // Good
    return 'bg-meter-low'; // Low
  };

  const isVertical = orientation === 'vertical';

  return (
    <div
      className={`relative bg-bg-deep rounded overflow-hidden ${className}`}
      style={isVertical ? { width: 12, height } : { height: 12, width: height }}
    >
      {/* Background gradient markers */}
      <div className="absolute inset-0 flex flex-col justify-between opacity-20">
        <div className="h-px bg-meter-clip" style={{ marginTop: '5%' }} />
        <div className="h-px bg-meter-hot" style={{ marginTop: '15%' }} />
        <div className="h-px bg-bg-disabled" style={{ marginTop: '50%' }} />
      </div>

      {/* Current level (RMS/position) */}
      <div
        className={`absolute ${getColor(posPercent)} ${hasMounted ? 'transition-all duration-75' : ''} ${
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

      {/* Clip indicator - tap to clear */}
      {track?.clipped && (
        <div
          className={`absolute bg-meter-clip animate-pulse cursor-pointer ${
            isVertical ? 'top-0 left-0 right-0 h-2' : 'right-0 top-0 bottom-0 w-2'
          }`}
          onClick={() => sendCommand(meter.clearClip(trackIndex))}
          title="Tap to clear clip"
        />
      )}
    </div>
  );
}
