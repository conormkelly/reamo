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

import type { ReactElement } from 'react';
import {
  Play,
  Pause,
  Square,
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
import { useRecordButton } from '../../hooks/useRecordButton';
import { type ViewId, viewMeta } from '../../viewRegistry';
import { RecordModeIcon } from '../Transport/RecordModeIcon';
import { recordModeTitle } from '../../hooks/useRecordButton';

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
  const { isPlaying, isPaused, isStopped, play, pause, stop } = useTransport();
  const hiddenViews = useReaperStore((s) => s.hiddenViews);
  const viewOrder = useReaperStore((s) => s.viewOrder);
  const visibleViews = viewOrder.filter(v => !hiddenViews.includes(v));
  const { pointerHandlers, recordMode, isRecording } = useRecordButton();

  // Transport handlers
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleStop = () => sendCommand(stop());

  const recordInactiveClass = recordMode !== 'normal'
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

        {/* Record - with long-press for record mode cycling */}
        <button
          {...pointerHandlers}
          className={`
            w-10 h-10 rounded-full flex items-center justify-center transition-colors touch-none
            ${isRecording ? 'bg-record animate-pulse' : recordInactiveClass}
          `}
          title={recordModeTitle(recordMode)}
          aria-label={recordModeTitle(recordMode)}
          aria-pressed={isRecording}
        >
          <RecordModeIcon mode={recordMode} size={14} />
        </button>
      </div>
    </nav>
  );
}
