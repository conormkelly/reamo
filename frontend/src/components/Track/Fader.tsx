/**
 * Fader Component
 * Vertical volume fader with drag support and double-tap to reset
 */

import { useState, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';
import { gesture } from '../../core/WebSocketCommands';

/** Linear volume for unity gain (0dB) - exactly 1.0 */
const UNITY_GAIN_VOLUME = 1.0;

export interface FaderProps {
  trackIndex: number;
  className?: string;
  height?: number;
  /** Linear volume to reset to on double-tap (default: 1.0 = unity/0dB) */
  resetVolume?: number;
  /** Whether parent track is selected (affects background brightness) */
  isSelected?: boolean;
}

export function Fader({
  trackIndex,
  className = '',
  height = 150,
  resetVolume = UNITY_GAIN_VOLUME,
  isSelected = false,
}: FaderProps): ReactElement {
  const { sendCommand } = useReaper();
  const { faderPosition, volumeDb, setFaderPosition, setVolume } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);

  // Cleanup event listeners on unmount to prevent memory leaks
  useEffect(() => {
    return () => {
      if (cleanupRef.current) {
        cleanupRef.current();
      }
    };
  }, []);

  // Handle double-tap to reset to unity - use setVolume directly to avoid fader curve round-trip
  const handleDoubleTap = useCallback(() => {
    sendCommand(setVolume(resetVolume));
  }, [sendCommand, setVolume, resetVolume]);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      // Ignore input when mixer is locked
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastTapRef.current < 300) {
        // Double tap detected - reset to unity
        e.preventDefault();
        lastTapRef.current = 0;
        handleDoubleTap();
        return;
      }
      lastTapRef.current = now;

      e.preventDefault();
      setIsDragging(true);

      // Signal gesture start for undo coalescing
      sendCommand(gesture.start('volume', trackIndex));

      const getY = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientY;
        }
        return event.clientY;
      };

      const updatePosition = (clientY: number) => {
        if (!containerRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const y = clientY - rect.top;
        const position = 1 - Math.max(0, Math.min(1, y / rect.height));
        sendCommand(setFaderPosition(position));
      };

      // Handle initial click position
      const initialY = 'touches' in e ? e.touches[0].clientY : e.clientY;
      updatePosition(initialY);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePosition(getY(event));
      };

      const handleUp = () => {
        setIsDragging(false);
        // Signal gesture end - triggers undo point creation
        sendCommand(gesture.end('volume', trackIndex));
        document.removeEventListener('mousemove', handleMove);
        document.removeEventListener('mouseup', handleUp);
        document.removeEventListener('touchmove', handleMove);
        document.removeEventListener('touchend', handleUp);
        cleanupRef.current = null;
      };

      document.addEventListener('mousemove', handleMove);
      document.addEventListener('mouseup', handleUp);
      document.addEventListener('touchmove', handleMove, { passive: false });
      document.addEventListener('touchend', handleUp);

      // Store cleanup function for unmount
      cleanupRef.current = handleUp;
    },
    [sendCommand, setFaderPosition, handleDoubleTap, mixerLocked, trackIndex]
  );

  const handleHeight = Math.max(0, Math.min(height, faderPosition * height));

  return (
    <div className={`flex flex-col items-center gap-1 ${className}`}>
      <div
        ref={containerRef}
        className={`relative w-8 rounded select-none ${
          isSelected ? 'bg-gray-500' : 'bg-gray-700'
        } ${mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ns-resize'} ${
          isDragging ? 'ring-2 ring-blue-400' : ''
        }`}
        style={{ height }}
        onMouseDown={handleMouseDown}
        onTouchStart={handleMouseDown}
        title="Volume - double-tap to reset to 0dB"
      >
        {/* Fader track */}
        <div
          className="absolute bottom-0 left-0 right-0 bg-green-600 rounded-b transition-all duration-75"
          style={{ height: handleHeight }}
        />
        {/* Fader handle */}
        <div
          className="absolute left-0 right-0 h-3 bg-white rounded shadow-md transition-all duration-75"
          style={{ bottom: Math.max(0, handleHeight - 6) }}
        />
      </div>
      <span className="text-xs text-gray-400 font-mono">{volumeDb}</span>
    </div>
  );
}
