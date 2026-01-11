/**
 * Pan Knob Component
 * Horizontal pan control with drag support and double-tap to center
 */

import { useState, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';
import { gesture, track as trackCmd } from '../../core/WebSocketCommands';

/** Center pan position */
const CENTER_PAN = 0;

export interface PanKnobProps {
  trackIndex: number;
  className?: string;
  /** Width of the pan slider */
  width?: number;
  /** Whether parent track is selected (affects background brightness) */
  isSelected?: boolean;
}

/**
 * Horizontal pan control
 *
 * - Drag left/right to adjust pan
 * - Double-tap to reset to center
 *
 * @example
 * ```tsx
 * <PanKnob trackIndex={1} />
 * <PanKnob trackIndex={0} width={100} />
 * ```
 */
export function PanKnob({
  trackIndex,
  className = '',
  width = 80,
  isSelected = false,
}: PanKnobProps): ReactElement {
  const { sendCommand } = useReaper();
  const { pan, panDisplay, setPan, guid } = useTrack(trackIndex);
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

  // Handle double-tap to center pan
  const handleDoubleTap = useCallback(() => {
    sendCommand(setPan(CENTER_PAN));
  }, [sendCommand, setPan]);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      // Ignore input when mixer is locked
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastTapRef.current < 300) {
        // Double tap detected - center pan
        e.preventDefault();
        lastTapRef.current = 0;
        handleDoubleTap();
        return;
      }
      lastTapRef.current = now;

      // REQUIRE GUID for gestures - prevents modifying wrong track if reordered
      if (!guid) {
        console.warn(`PanKnob: No GUID for track ${trackIndex}, gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsDragging(true);

      // Lock GUID at gesture start - use this for ALL commands during gesture
      gestureGuidRef.current = guid;

      // Signal gesture start for undo coalescing (with locked GUID)
      sendCommand(gesture.start('pan', trackIndex, gestureGuidRef.current));

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePosition = (clientX: number) => {
        if (!containerRef.current || !gestureGuidRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        // Convert to -1 to 1 range
        const position = (x / rect.width) * 2 - 1;
        const clampedPosition = Math.max(-1, Math.min(1, position));
        // Use locked GUID for pan command (ignores trackIdx when GUID provided)
        sendCommand(trackCmd.setPan(trackIndex, clampedPosition, gestureGuidRef.current));
      };

      // Handle initial click position
      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePosition(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePosition(getX(event));
      };

      const handleUp = () => {
        setIsDragging(false);
        // Signal gesture end with locked GUID - triggers undo point creation
        if (gestureGuidRef.current) {
          sendCommand(gesture.end('pan', trackIndex, gestureGuidRef.current));
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

  // Calculate indicator position (0-100%)
  const indicatorPosition = ((pan + 1) / 2) * 100;

  return (
    <div className={`flex flex-col items-center gap-1 ${className}`}>
      <div
        ref={containerRef}
        className={`relative h-4 rounded touch-none ${
          isSelected ? 'bg-bg-disabled' : 'bg-bg-elevated'
        } ${mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'} ${
          isDragging ? 'ring-2 ring-control-ring' : ''
        }`}
        style={{ width }}
        onMouseDown={handleMouseDown}
        onTouchStart={handleMouseDown}
        title="Pan - double-tap to center"
      >
        {/* Center line */}
        <div className="absolute top-0 bottom-0 left-1/2 w-px bg-bg-hover" />

        {/* Pan indicator */}
        <div
          className={`absolute top-0.5 bottom-0.5 w-2 rounded transition-all duration-75 ${
            isSelected ? 'bg-control-indicator-selected' : 'bg-control-indicator'
          }`}
          style={{ left: `calc(${indicatorPosition}% - 4px)` }}
        />
      </div>
      <span className="text-[10px] text-text-secondary font-mono whitespace-nowrap">{panDisplay}</span>
    </div>
  );
}
