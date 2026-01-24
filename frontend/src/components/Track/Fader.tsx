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
  /** Whether to show the dB label below the fader (default: true) */
  showDbLabel?: boolean;
}

export function Fader({
  trackIndex,
  className = '',
  height = 150,
  resetVolume = UNITY_GAIN_VOLUME,
  isSelected = false,
  showDbLabel = true,
}: FaderProps): ReactElement {
  const { sendCommand } = useReaper();
  const { faderPosition, volumeDb, setVolume, guid } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const [isDragging, setIsDragging] = useState(false);
  const [isFineMode, setIsFineMode] = useState(false);
  const [hasMounted, setHasMounted] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);
  // Lock GUID at gesture start to handle track reordering during drag
  const gestureGuidRef = useRef<string | null>(null);
  // Fine-grained control: track initial position for delta-based movement
  const dragStartRef = useRef<{ x: number; y: number; faderPos: number } | null>(null);

  // Enable transitions only after first render to prevent blip on remount
  useEffect(() => {
    // Small delay to ensure initial position is set before enabling transitions
    const timer = setTimeout(() => setHasMounted(true), 50);
    return () => clearTimeout(timer);
  }, []);

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

      const getXY = (event: MouseEvent | TouchEvent | React.MouseEvent | React.TouchEvent): { x: number; y: number } => {
        if ('touches' in event && event.touches.length > 0) {
          return { x: event.touches[0].clientX, y: event.touches[0].clientY };
        }
        if ('clientX' in event) {
          return { x: event.clientX, y: event.clientY };
        }
        return { x: 0, y: 0 };
      };

      // Capture initial position for delta-based fine control
      const initial = getXY(e as React.MouseEvent | React.TouchEvent);
      dragStartRef.current = {
        x: initial.x,
        y: initial.y,
        faderPos: faderPosition,
      };

      // Threshold for fine mode indicator (px away from fader)
      const FINE_MODE_THRESHOLD = 30;
      // Sensitivity scaling factor (lower = more sensitive to horizontal distance)
      const SENSITIVITY_DIVISOR = 50;

      const updatePosition = (clientX: number, clientY: number) => {
        if (!containerRef.current || !gestureGuidRef.current || !dragStartRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();

        // Calculate horizontal offset from start position
        const horizontalOffset = Math.abs(clientX - dragStartRef.current.x);

        // Calculate sensitivity: 1.0 at fader, decreasing as finger moves away
        // At 50px away: 0.5x, at 100px: 0.33x, at 150px: 0.25x
        const sensitivity = 1 / (1 + horizontalOffset / SENSITIVITY_DIVISOR);

        // Update fine mode indicator
        setIsFineMode(horizontalOffset > FINE_MODE_THRESHOLD);

        // Calculate vertical delta from start (negative = up = increase)
        const deltaY = clientY - dragStartRef.current.y;

        // Apply scaled delta to initial position
        // deltaY / height gives normalized movement, scaled by sensitivity
        const deltaPosition = -(deltaY / rect.height) * sensitivity;
        const newPosition = Math.max(0, Math.min(1, dragStartRef.current.faderPos + deltaPosition));

        // Use locked GUID for volume command (ignores trackIdx when GUID provided)
        const linearVolume = faderToVolume(newPosition);
        sendCommand(trackCmd.setVolume(trackIndex, linearVolume, gestureGuidRef.current));
      };

      // Handle initial click position (just sets starting point, no movement yet)
      // Don't update position on initial click - wait for movement

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        const { x, y } = getXY(event);
        updatePosition(x, y);
      };

      const handleUp = () => {
        setIsDragging(false);
        setIsFineMode(false);
        dragStartRef.current = null;
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
    [sendCommand, handleDoubleTap, mixerLocked, trackIndex, guid, faderPosition]
  );

  const handleHeight = Math.max(0, Math.min(height, faderPosition * height));

  return (
    <div className={`flex flex-col items-center gap-1 ${className}`}>
      <div
        ref={containerRef}
        className={`relative w-8 rounded touch-none ${
          isSelected ? 'bg-bg-disabled' : 'bg-bg-elevated'
        } ${mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ns-resize'} ${
          isDragging ? 'ring-2 ring-control-ring' : ''
        }`}
        style={{ height }}
        onMouseDown={handleMouseDown}
        onTouchStart={handleMouseDown}
        title="Volume - double-tap to reset to 0dB"
      >
        {/* Fader track */}
        <div
          className={`absolute bottom-0 left-0 right-0 bg-fader-fill rounded-b ${hasMounted ? 'transition-all duration-75' : ''}`}
          style={{ height: handleHeight }}
        />
        {/* Fader handle */}
        <div
          className={`absolute left-0 right-0 h-3 bg-fader-handle rounded shadow-md ${hasMounted ? 'transition-all duration-75' : ''}`}
          style={{ bottom: Math.max(0, handleHeight - 6) }}
        />
        {/* Fine mode indicator */}
        {isFineMode && (
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
            <span className="text-[8px] font-bold text-primary bg-bg-deep/80 px-1 rounded">
              FINE
            </span>
          </div>
        )}
      </div>
      {showDbLabel && (
        <span className="text-[10px] text-text-secondary font-mono whitespace-nowrap w-[52px] text-center">{volumeDb}</span>
      )}
    </div>
  );
}
