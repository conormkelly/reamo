/**
 * Timeline Mode Toggle Component
 * Switches between Navigate and Regions modes
 *
 * Items mode has been removed - item selection is now done by tapping
 * density blobs in Navigate mode, with NavigateItemInfoBar showing controls.
 */

import { useEffect, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import type { TimelineMode } from '../../store';

// LocalStorage key
const TIMELINE_MODE_KEY = 'reamo-timeline-mode';

export function TimelineModeToggle(): ReactElement | null {
  const setTimelineMode = useReaperStore((s) => s.setTimelineMode);

  // Temporarily hidden pre-launch — region editing needs more polish.
  // Force navigate mode and ensure any stale localStorage is migrated.
  useEffect(() => {
    try {
      const saved = localStorage.getItem(TIMELINE_MODE_KEY) as TimelineMode | null;
      if (saved && saved !== 'navigate') {
        localStorage.setItem(TIMELINE_MODE_KEY, 'navigate');
      }
    } catch {
      // Ignore storage errors
    }
    setTimelineMode('navigate');
  }, [setTimelineMode]);

  return null;
}
