/**
 * Record Arm Button Component
 * Toggle record arm state for a track
 * Long-press opens input selection sheet
 */

import { useState, type ReactElement } from 'react';
import { Circle } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';
import { useLongPress } from '../../hooks/useLongPress';
import { InputSelectionSheet } from '../Mixer';

export interface RecordArmButtonProps {
  trackIndex: number;
  className?: string;
  /** Whether parent track is selected (affects background) */
  isSelected?: boolean;
}

export function RecordArmButton({
  trackIndex,
  className = '',
  isSelected = false,
}: RecordArmButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isRecordArmed, toggleRecordArm, guid } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  // Input selection sheet state
  const [showInputSheet, setShowInputSheet] = useState(false);

  // Long-press handler for input selection
  const { handlers } = useLongPress({
    onTap: () => {
      if (mixerLocked) return;
      sendCommand(toggleRecordArm());
    },
    onLongPress: () => {
      if (mixerLocked) return;
      setShowInputSheet(true);
    },
    duration: 400,
  });

  // Buttons always darker than track background for contrast
  const inactiveBg = isSelected
    ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
    : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';

  return (
    <>
      <button
        {...handlers}
        aria-pressed={isRecordArmed}
        title={isRecordArmed ? 'Disarm Track (long-press for input)' : 'Arm Track for Recording (long-press for input)'}
        className={`px-2 py-1 rounded text-sm font-medium transition-colors ${
          mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
        } ${isRecordArmed ? 'bg-error-action text-text-on-error' : inactiveBg} ${className}`}
      >
        <Circle size={14} className={`inline-block ${isRecordArmed ? 'fill-current' : ''}`} />
      </button>

      {guid && (
        <InputSelectionSheet
          isOpen={showInputSheet}
          onClose={() => setShowInputSheet(false)}
          trackIndex={trackIndex}
          trackGuid={guid}
        />
      )}
    </>
  );
}
