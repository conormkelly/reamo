/**
 * NavRail Component (formerly SideRail)
 * Vertical navigation rail for landscape-constrained viewports (phones in landscape)
 *
 * Contains:
 * - View navigation tabs (vertical icons)
 * - Transport controls (play/stop/record)
 * - Safe area handling for notch on left side
 *
 * Part of dual-rail layout: NavRail (left) + ContextRail (right)
 * Replaces TabBar + PersistentTransport when navPosition === 'side'
 *
 * @see docs/architecture/RESPONSIVE_FRONTEND_FINAL.md
 */

import { type ReactElement, useRef, useEffect, useCallback } from 'react';
import {
  Play,
  Pause,
  Square,
  Circle,
  RefreshCw,
  SlidersHorizontal,
  Clock,
  ListMusic,
  Zap,
  StickyNote,
  Music,
  ChartBarBig,
  AudioWaveform,
} from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import { useReaperStore } from '../../store';
import { type ViewId, viewMeta } from '../../viewRegistry';

/** Icons for each view */
const VIEW_ICONS: Record<ViewId, typeof SlidersHorizontal> = {
  timeline: ChartBarBig,
  mixer: SlidersHorizontal,
  clock: Clock,
  playlist: ListMusic,
  actions: Zap,
  notes: StickyNote,
  instruments: Music,
  tuner: AudioWaveform,
};

// Hold duration threshold for record button mode toggle
const RECORD_HOLD_THRESHOLD = 300;

// =============================================================================
// Types
// =============================================================================

export interface SideRailProps {
  currentView: ViewId;
  onViewChange: (view: ViewId) => void;
  className?: string;
}

// =============================================================================
// Component
// =============================================================================

export function SideRail({ currentView, onViewChange, className = '' }: SideRailProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop, record } = useTransport();
  const isAutoPunch = useReaperStore((state) => state.isAutoPunch);
  const hiddenViews = useReaperStore((s) => s.hiddenViews);
  const viewOrder = useReaperStore((s) => s.viewOrder);
  const visibleViews = viewOrder.filter(v => !hiddenViews.includes(v));

  // Long-press state for Record button
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

  // Transport handlers
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleStop = () => sendCommand(stop());

  // Record button long-press handlers (same as PersistentTransport)
  const handleRecordPointerDown = useCallback(() => {
    wasHoldRef.current = false;
    holdTimerRef.current = setTimeout(() => {
      wasHoldRef.current = true;
      // TODO: Toggle auto-punch mode
    }, RECORD_HOLD_THRESHOLD);
  }, []);

  const handleRecordPointerUp = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    if (!wasHoldRef.current) {
      sendCommand(record());
    }
  }, [sendCommand, record]);

  const handleRecordPointerCancel = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
  }, []);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
      }
    };
  }, []);

  const recordInactiveClass = isAutoPunch
    ? 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring'
    : 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring-dim';

  return (
    <nav
      className={`
        flex flex-col h-full shrink-0
        bg-bg-deep border-r border-border-muted
        nav-rail-width safe-area-left-landscape safe-area-top
        ${className}
      `}
      aria-label="Main navigation"
      data-testid="nav-rail"
    >
      {/* View navigation tabs - icons only, vertical */}
      <div className="flex-1 flex flex-col items-center py-2 gap-1 overflow-y-auto scrollbar-hide">
        {visibleViews.map((viewId) => {
          const meta = viewMeta[viewId];
          const Icon = VIEW_ICONS[viewId];
          const isActive = currentView === viewId;

          return (
            <button
              key={viewId}
              onClick={() => onViewChange(viewId)}
              className={`
                w-11 h-11 rounded-lg flex items-center justify-center
                transition-colors
                ${isActive
                  ? 'bg-bg-surface text-text-primary border-l-2 border-primary'
                  : 'text-text-secondary hover:text-text-primary hover:bg-bg-surface/50'
                }
              `}
              title={meta.label}
              aria-label={meta.label}
              aria-current={isActive ? 'page' : undefined}
            >
              <Icon size={20} strokeWidth={isActive ? 2 : 1.5} />
            </button>
          );
        })}
      </div>

      {/* Transport controls - fixed at bottom */}
      <div className="shrink-0 border-t border-border-subtle py-2 px-1 flex flex-col items-center gap-1.5 safe-area-bottom">
        {/* Play/Pause toggle */}
        <button
          onClick={isPlaying ? handlePause : handlePlay}
          className={`
            w-10 h-10 rounded-full flex items-center justify-center transition-colors
            ${isPlaying ? 'bg-success' : 'bg-bg-elevated hover:bg-bg-hover'}
          `}
          title={isPlaying ? 'Pause' : 'Play'}
          aria-label={isPlaying ? 'Pause' : 'Play'}
          aria-pressed={isPlaying}
        >
          {isPlaying ? (
            <Pause size={16} fill="currentColor" />
          ) : (
            <Play size={16} fill={isPaused ? 'none' : 'currentColor'} />
          )}
        </button>

        {/* Stop */}
        <button
          onClick={handleStop}
          className={`
            w-10 h-10 rounded-full flex items-center justify-center transition-colors
            ${isStopped ? 'bg-bg-hover' : 'bg-bg-elevated hover:bg-bg-hover'}
          `}
          title="Stop"
          aria-label="Stop"
          aria-pressed={isStopped}
        >
          <Square size={12} fill={isStopped ? 'currentColor' : 'none'} />
        </button>

        {/* Record - with long-press for auto-punch toggle */}
        <button
          onPointerDown={handleRecordPointerDown}
          onPointerUp={handleRecordPointerUp}
          onPointerCancel={handleRecordPointerCancel}
          onPointerLeave={handleRecordPointerCancel}
          className={`
            w-10 h-10 rounded-full flex items-center justify-center transition-colors touch-none
            ${isRecording ? 'bg-record animate-pulse' : recordInactiveClass}
          `}
          title={isAutoPunch ? 'Record (Auto-Punch) - hold to toggle mode' : 'Record - hold to toggle auto-punch'}
          aria-label={isAutoPunch ? 'Record (Auto-Punch mode)' : 'Record'}
          aria-pressed={isRecording}
        >
          {isAutoPunch ? (
            <RefreshCw size={14} strokeWidth={2.5} />
          ) : (
            <Circle size={14} fill="currentColor" />
          )}
        </button>
      </div>
    </nav>
  );
}
