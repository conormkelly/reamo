/**
 * Timeline Mode Toggle Component
 * Switches between Navigate, Regions, and Items modes
 */

import { useEffect, type ReactElement } from 'react';
import { Navigation, Layers, AudioLines } from 'lucide-react';
import { useReaperStore } from '../../store';
import type { TimelineMode } from '../../store';

// LocalStorage key
const TIMELINE_MODE_KEY = 'reamo-timeline-mode';

// Valid timeline modes for persistence
const VALID_MODES: TimelineMode[] = ['navigate', 'regions', 'items'];

export function TimelineModeToggle(): ReactElement {
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const setTimelineMode = useReaperStore((s) => s.setTimelineMode);
  // Subscribe to pendingChanges directly so component re-renders when it changes
  const pendingChanges = useReaperStore((s) => s.pendingChanges);
  const hasPending = Object.keys(pendingChanges).length > 0;

  // Load persisted mode from localStorage on mount
  useEffect(() => {
    try {
      const savedTimelineMode = localStorage.getItem(TIMELINE_MODE_KEY) as TimelineMode | null;
      if (savedTimelineMode && VALID_MODES.includes(savedTimelineMode)) {
        setTimelineMode(savedTimelineMode);
      }
    } catch {
      // Ignore storage errors
    }
  }, [setTimelineMode]);

  // Persist mode changes to localStorage
  useEffect(() => {
    try {
      localStorage.setItem(TIMELINE_MODE_KEY, timelineMode);
    } catch {
      // Ignore quota exceeded errors on iOS
    }
  }, [timelineMode]);

  const handleTimelineModeChange = (mode: TimelineMode) => {
    // Don't allow switching modes if there are pending changes
    if (hasPending) {
      return;
    }
    setTimelineMode(mode);
  };

  return (
    <div className="flex items-center gap-3">
      {/* Timeline Mode Toggle */}
      <div className="flex rounded-lg overflow-hidden border border-border-default">
        <button
          onClick={() => handleTimelineModeChange('navigate')}
          disabled={hasPending}
          className={`flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium transition-colors ${
            timelineMode === 'navigate'
              ? 'bg-primary text-text-primary'
              : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
          } ${hasPending ? 'cursor-not-allowed opacity-50' : ''}`}
          title="Navigate mode: Tap to seek, drag for time selection"
        >
          <Navigation size={14} />
          <span className="hidden sm:inline">Navigate</span>
        </button>
        <button
          onClick={() => handleTimelineModeChange('items')}
          disabled={hasPending}
          className={`flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium transition-colors ${
            timelineMode === 'items'
              ? 'bg-success-action text-text-primary'
              : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
          } ${hasPending ? 'cursor-not-allowed opacity-50' : ''}`}
          title="Items mode: View waveforms and manage takes"
        >
          <AudioLines size={14} />
          <span className="hidden sm:inline">Items</span>
        </button>
        <button
          onClick={() => handleTimelineModeChange('regions')}
          disabled={hasPending}
          className={`flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium transition-colors ${
            timelineMode === 'regions'
              ? 'bg-accent-region text-text-primary'
              : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
          } ${hasPending ? 'cursor-not-allowed opacity-50' : ''}`}
          title="Regions mode: Edit region positions (ripple edit)"
        >
          <Layers size={14} />
          <span className="hidden sm:inline">Regions</span>
        </button>
      </div>
    </div>
  );
}
