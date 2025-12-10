/**
 * Pan Knob Component
 * Horizontal pan control with drag support and double-tap to center
 */

import { useState, useCallback, useRef, type ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';

/** Center pan position */
const CENTER_PAN = 0;

export interface PanKnobProps {
  trackIndex: number;
  className?: string;
  /** Width of the pan slider */
  width?: number;
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
}: PanKnobProps): ReactElement {
  const { send } = useReaper();
  const { pan, panDisplay, setPan } = useTrack(trackIndex);
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);

  // Handle double-tap to center pan
  const handleDoubleTap = useCallback(() => {
    send(setPan(CENTER_PAN));
  }, [send, setPan]);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
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

      e.preventDefault();
      setIsDragging(true);

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePosition = (clientX: number) => {
        if (!containerRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        // Convert to -1 to 1 range
        const position = (x / rect.width) * 2 - 1;
        const clampedPosition = Math.max(-1, Math.min(1, position));
        send(setPan(clampedPosition));
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
        document.removeEventListener('mousemove', handleMove);
        document.removeEventListener('mouseup', handleUp);
        document.removeEventListener('touchmove', handleMove);
        document.removeEventListener('touchend', handleUp);
      };

      document.addEventListener('mousemove', handleMove);
      document.addEventListener('mouseup', handleUp);
      document.addEventListener('touchmove', handleMove, { passive: false });
      document.addEventListener('touchend', handleUp);
    },
    [send, setPan, handleDoubleTap]
  );

  // Calculate indicator position (0-100%)
  const indicatorPosition = ((pan + 1) / 2) * 100;

  return (
    <div className={`flex flex-col items-center gap-1 ${className}`}>
      <div
        ref={containerRef}
        className={`relative h-4 bg-gray-800 rounded cursor-ew-resize select-none ${
          isDragging ? 'ring-2 ring-blue-400' : ''
        }`}
        style={{ width }}
        onMouseDown={handleMouseDown}
        onTouchStart={handleMouseDown}
        title="Pan - double-tap to center"
      >
        {/* Center line */}
        <div className="absolute top-0 bottom-0 left-1/2 w-px bg-gray-600" />

        {/* Pan indicator */}
        <div
          className="absolute top-0.5 bottom-0.5 w-2 bg-blue-500 rounded transition-all duration-75"
          style={{ left: `calc(${indicatorPosition}% - 4px)` }}
        />
      </div>
      <span className="text-xs text-gray-400 font-mono">{panDisplay}</span>
    </div>
  );
}
