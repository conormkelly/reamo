/**
 * Take Switcher Component
 * Allows switching between takes on the selected track within the time selection
 * Only visible when at least one track is selected
 * Only enabled when exactly one track is selected and a time selection exists
 */

import type { ReactElement } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useReaper } from './ReaperProvider';
import { useTracks } from '../hooks/useTracks';
import { useReaperStore } from '../store';
import * as commands from '../core/CommandBuilder';

export interface TakeSwitcherProps {
  className?: string;
}

export function TakeSwitcher({ className = '' }: TakeSwitcherProps): ReactElement | null {
  const { send } = useReaper();
  const { selectedTracks } = useTracks();
  const timeSelection = useReaperStore((state) => state.timeSelection);

  // Don't render if no tracks are selected
  if (selectedTracks.length === 0) {
    return null;
  }

  // Enabled when exactly one track is selected AND time selection exists
  const hasTimeSelection = timeSelection !== null;
  const hasSingleTrackSelected = selectedTracks.length === 1;
  const hasMultipleTracks = selectedTracks.length > 1;
  const isEnabled = hasTimeSelection && hasSingleTrackSelected;

  // Build selected track display
  const getSelectedTrackDisplay = (): string => {
    if (hasSingleTrackSelected) {
      return selectedTracks[0].name || `Track ${selectedTracks[0].index}`;
    }
    return `${selectedTracks.length} tracks`;
  };

  const handlePrevTake = () => {
    if (!isEnabled) return;
    // Select items in time selection on selected track, then switch to previous take
    send(
      commands.join(
        commands.selectItemsInTimeSelection(),
        commands.previousTake()
      )
    );
  };

  const handleNextTake = () => {
    if (!isEnabled) return;
    // Select items in time selection on selected track, then switch to next take
    send(
      commands.join(
        commands.selectItemsInTimeSelection(),
        commands.nextTake()
      )
    );
  };

  // Determine hint text when take switching isn't available
  const getHintText = (): string | null => {
    if (hasMultipleTracks) {
      return 'Select one track for take switching';
    }
    if (!hasTimeSelection) {
      return 'Select a region to switch takes';
    }
    return null;
  };

  const hintText = getHintText();

  return (
    <div className={`${className}`}>
      {/* Section header */}
      <div className="flex items-center justify-center gap-2 mb-2">
        <span className="text-xs text-gray-500 uppercase tracking-wider">Takes</span>
        <span className="text-xs text-gray-400">·</span>
        <span className="text-xs text-blue-400">{getSelectedTrackDisplay()}</span>
      </div>

      {/* Take controls or hint */}
      <div className="flex items-center justify-center gap-2">
        {isEnabled ? (
          <>
            <button
              onClick={handlePrevTake}
              className="flex items-center gap-1 px-3 py-1.5 bg-gray-800 hover:bg-gray-700 active:bg-gray-600 active:scale-95 rounded text-sm font-medium transition-all"
              title="Switch to previous take"
            >
              <ChevronLeft className="w-4 h-4" />
              Prev Take
            </button>
            <button
              onClick={handleNextTake}
              className="flex items-center gap-1 px-3 py-1.5 bg-gray-800 hover:bg-gray-700 active:bg-gray-600 active:scale-95 rounded text-sm font-medium transition-all"
              title="Switch to next take"
            >
              Next Take
              <ChevronRight className="w-4 h-4" />
            </button>
          </>
        ) : (
          <span className="text-xs text-gray-500 italic">
            {hintText}
          </span>
        )}
      </div>
    </div>
  );
}
