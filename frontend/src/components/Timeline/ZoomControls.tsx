/**
 * Zoom Controls Component
 * Compact zoom button that reveals zoom in/out buttons on tap
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { ZoomOut, ZoomIn, Maximize2 } from 'lucide-react';

export interface ZoomControlsProps {
  /** Current visible duration in seconds */
  visibleDuration: number;
  /** Zoom in callback */
  onZoomIn: () => void;
  /** Zoom out callback */
  onZoomOut: () => void;
  /** Fit to content callback */
  onFitToContent?: () => void;
  /** Optional className for container */
  className?: string;
}

/**
 * Format duration for display
 * @param seconds Duration in seconds
 * @returns Formatted string (e.g., "30s", "2m", "1h")
 */
function formatDuration(seconds: number): string {
  if (seconds < 60) {
    return `${Math.round(seconds)}s`;
  }
  if (seconds < 3600) {
    const minutes = Math.round(seconds / 60);
    return `${minutes}m`;
  }
  const hours = Math.round(seconds / 3600);
  return `${hours}h`;
}

export function ZoomControls({
  visibleDuration,
  onZoomIn,
  onZoomOut,
  onFitToContent,
  className = '',
}: ZoomControlsProps): ReactElement {
  const [isOpen, setIsOpen] = useState(false);
  const popoverRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);

  // Close popover when clicking outside
  useEffect(() => {
    if (!isOpen) return;

    const handleClickOutside = (e: MouseEvent | TouchEvent) => {
      const target = e.target as Node;
      if (
        popoverRef.current &&
        !popoverRef.current.contains(target) &&
        buttonRef.current &&
        !buttonRef.current.contains(target)
      ) {
        setIsOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    document.addEventListener('touchstart', handleClickOutside);
    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('touchstart', handleClickOutside);
    };
  }, [isOpen]);

  const zoomButtonStyle =
    'p-3 rounded-lg transition-colors touch-none select-none text-text-secondary hover:bg-bg-hover active:bg-bg-surface';

  return (
    <div className={`relative flex items-center gap-1 ${className}`}>
      {/* Compact zoom button */}
      <button
        ref={buttonRef}
        onClick={() => setIsOpen(!isOpen)}
        className="flex flex-col items-center p-1.5 rounded-lg transition-colors touch-none select-none text-text-tertiary hover:bg-bg-hover hover:text-text-secondary active:bg-bg-surface"
        title="Zoom controls"
        aria-label="Open zoom controls"
        aria-expanded={isOpen}
      >
        <span className="text-[10px] font-medium leading-tight">Zoom</span>
        <span className="text-[10px] font-medium tabular-nums leading-tight">
          {formatDuration(visibleDuration)}
        </span>
      </button>

      {/* Zoom buttons popover */}
      {isOpen && (
        <div
          ref={popoverRef}
          className="absolute bottom-full right-0 mb-2 flex flex-col items-center bg-bg-elevated rounded-lg shadow-lg border border-border-subtle p-1"
        >
          <button
            onClick={onZoomIn}
            className={zoomButtonStyle}
            title="Zoom in"
            aria-label="Zoom in"
          >
            <ZoomIn size={20} />
          </button>
          <button
            onClick={onZoomOut}
            className={zoomButtonStyle}
            title="Zoom out"
            aria-label="Zoom out"
          >
            <ZoomOut size={20} />
          </button>
        </div>
      )}

      {/* Fit to content */}
      {onFitToContent && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onFitToContent();
          }}
          className="p-1.5 rounded transition-colors touch-none select-none text-text-tertiary hover:bg-bg-hover hover:text-text-secondary active:bg-bg-surface"
          title="Fit to content"
          aria-label="Fit to content"
        >
          <Maximize2 size={16} />
        </button>
      )}
    </div>
  );
}
