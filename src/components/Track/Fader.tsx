/**
 * Fader Component
 * Vertical volume fader with drag support
 */

import { useState, useCallback, useRef, type ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';

export interface FaderProps {
  trackIndex: number;
  className?: string;
  height?: number;
}

export function Fader({
  trackIndex,
  className = '',
  height = 150,
}: FaderProps): ReactElement {
  const { send } = useReaper();
  const { faderPosition, volumeDb, setFaderPosition } = useTrack(trackIndex);
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      e.preventDefault();
      setIsDragging(true);

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
        send(setFaderPosition(position));
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
    [send, setFaderPosition]
  );

  const handleHeight = Math.max(0, Math.min(height, faderPosition * height));

  return (
    <div className={`flex flex-col items-center gap-1 ${className}`}>
      <div
        ref={containerRef}
        className={`relative w-8 bg-gray-800 rounded cursor-ns-resize select-none ${
          isDragging ? 'ring-2 ring-blue-400' : ''
        }`}
        style={{ height }}
        onMouseDown={handleMouseDown}
        onTouchStart={handleMouseDown}
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
