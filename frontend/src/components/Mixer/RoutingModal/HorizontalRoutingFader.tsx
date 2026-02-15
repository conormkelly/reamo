/**
 * HorizontalRoutingFader - Unified horizontal fader for send/receive/hardware routing
 * Fully parameterized component that handles volume, pan, mute, and mode controls.
 */

import { useState, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { Volume2, VolumeX, Trash2 } from 'lucide-react';
import { useReaperStore } from '../../../store';
import { volumeToDbString, faderToVolume, volumeToFader } from '../../../utils/volume';
import { formatPan, MODE_LABELS, ROUTING_COLORS, type RoutingColorScheme } from './routingUtils';

export interface HorizontalRoutingFaderProps {
  /** Volume value (linear 0-4, where 1 = unity) */
  volume: number;
  /** Pan value (-1 to 1) */
  pan: number;
  /** Whether this routing is muted */
  muted: boolean;
  /** Routing mode (0=Post, 1=Pre-FX, 3=Post-FX) */
  mode: number;
  /** Display label for the routing destination/source */
  label: string;
  /** Color scheme variant */
  colorScheme: RoutingColorScheme;

  // Callbacks - parent handles command dispatch
  onVolumeChange: (volume: number) => void;
  onVolumeGestureStart: () => void;
  onVolumeGestureEnd: () => void;
  onPanChange: (pan: number) => void;
  onPanGestureStart: () => void;
  onPanGestureEnd: () => void;
  onMuteToggle: () => void;
  onModeToggle: () => void;
  onVolumeDoubleTap: () => void;
  onPanDoubleTap: () => void;
  /** Optional delete callback - when provided, shows a trash icon */
  onDelete?: () => void;
  /** Optional label tap callback - when provided, label becomes tappable */
  onLabelTap?: () => void;
}

export function HorizontalRoutingFader({
  volume,
  pan,
  muted,
  mode,
  label,
  colorScheme,
  onVolumeChange,
  onVolumeGestureStart,
  onVolumeGestureEnd,
  onPanChange,
  onPanGestureStart,
  onPanGestureEnd,
  onMuteToggle,
  onModeToggle,
  onVolumeDoubleTap,
  onPanDoubleTap,
  onDelete,
  onLabelTap,
}: HorizontalRoutingFaderProps): ReactElement {
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const colors = ROUTING_COLORS[colorScheme];

  // Volume fader state
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);

  // Pan slider state
  const [isPanDragging, setIsPanDragging] = useState(false);
  const panContainerRef = useRef<HTMLDivElement>(null);
  const lastPanTapRef = useRef<number>(0);
  const panCleanupRef = useRef<(() => void) | null>(null);

  // Delete confirmation state (tap once = armed/red, tap again = delete)
  const [deleteArmed, setDeleteArmed] = useState(false);
  const deleteTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (cleanupRef.current) cleanupRef.current();
      if (panCleanupRef.current) panCleanupRef.current();
      if (deleteTimeoutRef.current) clearTimeout(deleteTimeoutRef.current);
    };
  }, []);

  const faderPosition = volumeToFader(volume);
  const volumeDb = volumeToDbString(volume);
  const indicatorPosition = faderPosition * 100;
  const panPosition = ((pan + 1) / 2) * 100;

  // Volume fader mouse/touch handler
  const handleVolumeMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastTapRef.current < 300) {
        e.preventDefault();
        lastTapRef.current = 0;
        onVolumeDoubleTap();
        return;
      }
      lastTapRef.current = now;

      e.preventDefault();
      setIsDragging(true);
      onVolumeGestureStart();

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
        const position = Math.max(0, Math.min(1, x / rect.width));
        const linearVolume = faderToVolume(position);
        onVolumeChange(linearVolume);
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePosition(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePosition(getX(event));
      };

      const handleUp = () => {
        setIsDragging(false);
        onVolumeGestureEnd();
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

      cleanupRef.current = handleUp;
    },
    [mixerLocked, onVolumeChange, onVolumeGestureStart, onVolumeGestureEnd, onVolumeDoubleTap]
  );

  // Pan slider mouse/touch handler
  const handlePanMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastPanTapRef.current < 300) {
        e.preventDefault();
        lastPanTapRef.current = 0;
        onPanDoubleTap();
        return;
      }
      lastPanTapRef.current = now;

      e.preventDefault();
      setIsPanDragging(true);
      onPanGestureStart();

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePan = (clientX: number) => {
        if (!panContainerRef.current) return;
        const rect = panContainerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        const position = Math.max(0, Math.min(1, x / rect.width));
        const newPan = position * 2 - 1; // Convert 0-1 to -1 to 1
        onPanChange(newPan);
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePan(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePan(getX(event));
      };

      const handleUp = () => {
        setIsPanDragging(false);
        onPanGestureEnd();
        document.removeEventListener('mousemove', handleMove);
        document.removeEventListener('mouseup', handleUp);
        document.removeEventListener('touchmove', handleMove);
        document.removeEventListener('touchend', handleUp);
        panCleanupRef.current = null;
      };

      document.addEventListener('mousemove', handleMove);
      document.addEventListener('mouseup', handleUp);
      document.addEventListener('touchmove', handleMove, { passive: false });
      document.addEventListener('touchend', handleUp);

      panCleanupRef.current = handleUp;
    },
    [mixerLocked, onPanChange, onPanGestureStart, onPanGestureEnd, onPanDoubleTap]
  );

  return (
    <div className="py-2 space-y-2">
      {/* Row 1: Volume controls */}
      <div className="flex items-center gap-3">
        {/* Mute button */}
        <button
          onClick={onMuteToggle}
          className={`w-11 h-11 flex items-center justify-center rounded-lg transition-colors ${
            muted ? colors.mutedButton : colors.unmutedButton
          }`}
          title={muted ? 'Unmute' : 'Mute'}
        >
          {muted ? <VolumeX size={20} /> : <Volume2 size={20} />}
        </button>

        {/* Label */}
        {onLabelTap ? (
          <button
            onClick={onLabelTap}
            className="text-sm text-accent-primary w-24 truncate text-left"
            title={`${label} - tap to change`}
          >
            {label}
          </button>
        ) : (
          <span className="text-sm text-text-primary w-24 truncate" title={label}>
            {label}
          </span>
        )}

        {/* Horizontal fader */}
        <div
          ref={containerRef}
          className={`relative flex-1 h-8 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isDragging ? `ring-2 ${colors.ring}` : ''}`}
          onMouseDown={handleVolumeMouseDown}
          onTouchStart={handleVolumeMouseDown}
          title="Level - double-tap to reset to 0dB"
        >
          {/* Fill */}
          <div
            className={`absolute top-0 bottom-0 left-0 ${colors.faderFill} rounded-l transition-all duration-75`}
            style={{ width: `${indicatorPosition}%` }}
          />
          {/* Handle */}
          <div
            className={`absolute top-1 bottom-1 w-3 ${colors.faderHandle} rounded shadow-md transition-all duration-75`}
            style={{ left: `calc(${indicatorPosition}% - 6px)` }}
          />
        </div>

        {/* dB readout */}
        <span className={`text-xs font-mono w-16 text-right ${muted ? colors.dbMuted : colors.dbText}`}>
          {volumeDb}
        </span>
      </div>

      {/* Row 2: Pan and Mode controls */}
      <div className="flex items-center gap-3 pl-14">
        {/* Pan slider */}
        <div
          ref={panContainerRef}
          className={`relative flex-1 h-6 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isPanDragging ? `ring-2 ${colors.ring}` : ''}`}
          onMouseDown={handlePanMouseDown}
          onTouchStart={handlePanMouseDown}
          title="Pan - double-tap to center"
        >
          {/* Center line */}
          <div className="absolute top-0 bottom-0 left-1/2 w-px bg-border-subtle" />
          {/* Handle */}
          <div
            className={`absolute top-1 bottom-1 w-3 ${colors.faderHandle} rounded shadow-md transition-all duration-75`}
            style={{ left: `calc(${panPosition}% - 6px)` }}
          />
        </div>

        {/* Pan readout */}
        <span className="text-xs font-mono w-10 text-center text-text-secondary">
          {formatPan(pan)}
        </span>

        {/* Mode badge */}
        <button
          onClick={onModeToggle}
          disabled={mixerLocked}
          className={`px-2 py-1 text-xs rounded-md transition-colors ${
            mixerLocked
              ? 'bg-bg-surface text-text-muted cursor-not-allowed'
              : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
          }`}
          title={`Mode: ${MODE_LABELS[mode] || 'Unknown'} - tap to cycle`}
        >
          {MODE_LABELS[mode] || '?'}
        </button>

        {/* Delete button - tap once to arm (red), tap again to confirm */}
        {onDelete && (
          <button
            onClick={() => {
              if (!deleteArmed) {
                setDeleteArmed(true);
                deleteTimeoutRef.current = setTimeout(() => {
                  setDeleteArmed(false);
                }, 3000);
              } else {
                if (deleteTimeoutRef.current) clearTimeout(deleteTimeoutRef.current);
                setDeleteArmed(false);
                onDelete();
              }
            }}
            className={`w-8 h-8 flex items-center justify-center rounded transition-colors ${
              deleteArmed
                ? 'bg-error-bg text-error-text'
                : 'text-text-muted hover:text-error-text'
            }`}
            title={deleteArmed ? 'Tap again to confirm remove' : 'Remove'}
          >
            <Trash2 size={14} />
          </button>
        )}
      </div>
    </div>
  );
}
