/**
 * Fader Component
 * Vertical volume fader with drag support and double-tap to reset
 */

import { useState, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';
import { gesture, track as trackCmd } from '../../core/WebSocketCommands';
import { faderToVolume } from '../../utils/volume';

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
  const { faderPosition, volumeDb, setVolume, guid } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);
  // Lock GUID at gesture start to handle track reordering during drag
  const gestureGuidRef = useRef<string | null>(null);

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

      // REQUIRE GUID for gestures - prevents modifying wrong track if reordered
      if (!guid) {
        console.warn(`Fader: No GUID for track ${trackIndex}, gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsDragging(true);

      // Lock GUID at gesture start - use this for ALL commands during gesture
      gestureGuidRef.current = guid;

      // Signal gesture start for undo coalescing (with locked GUID)
      sendCommand(gesture.start('volume', trackIndex, gestureGuidRef.current));

      const getY = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientY;
        }
        return event.clientY;
      };

      const updatePosition = (clientY: number) => {
        if (!containerRef.current || !gestureGuidRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const y = clientY - rect.top;
        const position = 1 - Math.max(0, Math.min(1, y / rect.height));
        // Use locked GUID for volume command (ignores trackIdx when GUID provided)
        const linearVolume = faderToVolume(position);
        sendCommand(trackCmd.setVolume(trackIndex, linearVolume, gestureGuidRef.current));
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
        // Signal gesture end with locked GUID - triggers undo point creation
        if (gestureGuidRef.current) {
          sendCommand(gesture.end('volume', trackIndex, gestureGuidRef.current));
        }
        gestureGuidRef.current = null;
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
    [sendCommand, handleDoubleTap, mixerLocked, trackIndex, guid]
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
