/**
 * Timeline Mode Toggle Component
 * Switches between Navigate/Markers mode and Regions editing mode
 */

import { useEffect, type ReactElement } from 'react';
import { Navigation, Layers } from 'lucide-react';
import { useReaperStore } from '../../store';
import type { TimelineMode } from '../../store';

// LocalStorage key
const TIMELINE_MODE_KEY = 'reamo-timeline-mode';

export function TimelineModeToggle(): ReactElement {
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const setTimelineMode = useReaperStore((s) => s.setTimelineMode);
  const luaScriptInstalled = useReaperStore((s) => s.luaScriptInstalled);
  const luaScriptChecked = useReaperStore((s) => s.luaScriptChecked);
  // Subscribe to pendingChanges directly so component re-renders when it changes
  const pendingChanges = useReaperStore((s) => s.pendingChanges);
  const hasPending = Object.keys(pendingChanges).length > 0;

  // Load persisted mode from localStorage on mount
  useEffect(() => {
    const savedTimelineMode = localStorage.getItem(TIMELINE_MODE_KEY) as TimelineMode | null;

    if (savedTimelineMode && (savedTimelineMode === 'navigate' || savedTimelineMode === 'regions')) {
      // Only restore regions mode if script is installed
      if (savedTimelineMode === 'regions' && !luaScriptInstalled) {
        setTimelineMode('navigate');
      } else {
        setTimelineMode(savedTimelineMode);
      }
    }
  }, [luaScriptInstalled, setTimelineMode]);

  // Persist mode changes to localStorage
  useEffect(() => {
    localStorage.setItem(TIMELINE_MODE_KEY, timelineMode);
  }, [timelineMode]);

  const handleTimelineModeChange = (mode: TimelineMode) => {
    // Don't allow switching to regions mode if script not installed
    if (mode === 'regions' && !luaScriptInstalled) {
      return;
    }
    // Don't allow switching modes if there are pending changes
    if (hasPending) {
      return;
    }
    setTimelineMode(mode);
  };

  const regionsDisabled = !luaScriptInstalled && luaScriptChecked;

  return (
    <div className="flex items-center gap-3">
      {/* Timeline Mode Toggle */}
      <div className="flex rounded-lg overflow-hidden border border-gray-600">
        <button
          onClick={() => handleTimelineModeChange('navigate')}
          disabled={hasPending}
          className={`flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium transition-colors ${
            timelineMode === 'navigate'
              ? 'bg-blue-600 text-white'
              : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
          } ${hasPending ? 'cursor-not-allowed opacity-50' : ''}`}
          title="Navigate mode: Tap to seek, drag for time selection"
        >
          <Navigation size={14} />
          <span className="hidden sm:inline">Navigate</span>
        </button>
        <button
          onClick={() => handleTimelineModeChange('regions')}
          disabled={regionsDisabled || hasPending}
          className={`flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium transition-colors ${
            timelineMode === 'regions'
              ? 'bg-purple-600 text-white'
              : regionsDisabled
                ? 'bg-gray-800 text-gray-500 cursor-not-allowed'
                : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
          } ${hasPending ? 'cursor-not-allowed opacity-50' : ''}`}
          title={
            regionsDisabled
              ? 'Region editing requires Lua script installation'
              : 'Regions mode: Edit region positions (ripple edit)'
          }
        >
          <Layers size={14} />
          <span className="hidden sm:inline">Regions</span>
        </button>
      </div>

      {/* Script not installed warning */}
      {regionsDisabled && (
        <span className="text-xs text-amber-400" title="Install Reamo_RegionEdit.lua to enable region editing">
          Script required
        </span>
      )}
    </div>
  );
}
