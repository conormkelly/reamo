/**
 * TimelineSettingsSheet - Bottom sheet for timeline-specific settings
 *
 * Currently provides a stepper control for track lane count (1-8).
 */

import { Minus, Plus } from 'lucide-react';
import { BottomSheet } from './BottomSheet';
import { useReaperStore } from '../../store';

export interface TimelineSettingsSheetProps {
  isOpen: boolean;
  onClose: () => void;
}

const MIN_LANES = 1;
const MAX_LANES = 8;

export function TimelineSettingsSheet({ isOpen, onClose }: TimelineSettingsSheetProps) {
  const timelineLaneCount = useReaperStore((s) => s.timelineLaneCount);
  const setTimelineLaneCount = useReaperStore((s) => s.setTimelineLaneCount);

  const handleDecrement = () => {
    if (timelineLaneCount > MIN_LANES) {
      setTimelineLaneCount(timelineLaneCount - 1);
    }
  };

  const handleIncrement = () => {
    if (timelineLaneCount < MAX_LANES) {
      setTimelineLaneCount(timelineLaneCount + 1);
    }
  };

  return (
    <BottomSheet isOpen={isOpen} onClose={onClose} ariaLabel="Timeline settings">
      <div className="px-sheet-x pb-sheet-bottom">
        {/* Title */}
        <h2 className="text-lg font-semibold text-text-primary mb-4">Timeline Settings</h2>

        {/* Lane count stepper */}
        <div className="space-y-2">
          <label className="text-sm text-text-secondary">Track Lanes</label>
          <div className="flex items-center gap-4">
            <button
              onClick={handleDecrement}
              disabled={timelineLaneCount <= MIN_LANES}
              className="w-12 h-12 rounded-lg bg-bg-surface flex items-center justify-center
                         text-text-primary disabled:text-text-muted disabled:opacity-50
                         hover:bg-bg-elevated active:bg-bg-elevated transition-colors"
              aria-label="Decrease lane count"
            >
              <Minus size={20} />
            </button>

            <span className="text-2xl font-semibold text-text-primary min-w-[3ch] text-center">
              {timelineLaneCount}
            </span>

            <button
              onClick={handleIncrement}
              disabled={timelineLaneCount >= MAX_LANES}
              className="w-12 h-12 rounded-lg bg-bg-surface flex items-center justify-center
                         text-text-primary disabled:text-text-muted disabled:opacity-50
                         hover:bg-bg-elevated active:bg-bg-elevated transition-colors"
              aria-label="Increase lane count"
            >
              <Plus size={20} />
            </button>
          </div>
        </div>
      </div>
    </BottomSheet>
  );
}

export default TimelineSettingsSheet;
