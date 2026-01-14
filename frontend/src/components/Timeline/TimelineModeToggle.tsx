/**
 * Timeline Mode Toggle Component
 * Switches between Navigate and Regions modes
 *
 * Items mode has been removed - item selection is now done by tapping
 * density blobs in Navigate mode, with NavigateItemInfoBar showing controls.
 */

import { useEffect, type ReactElement } from 'react';
import { Navigation, Layers } from 'lucide-react';
import { useReaperStore } from '../../store';
import type { TimelineMode } from '../../store';

// LocalStorage key
const TIMELINE_MODE_KEY = 'reamo-timeline-mode';

// Valid timeline modes for persistence (items mode removed)
const VALID_MODES: TimelineMode[] = ['navigate', 'regions'];

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
      if (savedTimelineMode) {
        // Migrate 'items' mode to 'navigate' (items mode removed)
        const migratedMode = savedTimelineMode === 'items' ? 'navigate' : savedTimelineMode;
        if (VALID_MODES.includes(migratedMode as TimelineMode)) {
          setTimelineMode(migratedMode as TimelineMode);
        }
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
              ? 'bg-primary text-text-on-primary'
              : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
          } ${hasPending ? 'cursor-not-allowed opacity-50' : ''}`}
          title="Navigate mode: Tap to seek, drag for time selection, tap items to select"
        >
          <Navigation size={14} />
          <span className="hidden sm:inline">Navigate</span>
        </button>
        <button
          onClick={() => handleTimelineModeChange('regions')}
          disabled={hasPending}
          className={`flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium transition-colors ${
            timelineMode === 'regions'
              ? 'bg-accent-region text-text-on-accent'
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
