/**
 * Record Arm Button Component
 * Toggle record arm state for a track
 */

import type { ReactElement } from 'react';
import { Circle } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';

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
  const { isRecordArmed, toggleRecordArm } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  const handleClick = () => {
    if (mixerLocked) return;
    sendCommand(toggleRecordArm());
  };

  // Buttons always darker than track background for contrast
  const inactiveBg = isSelected
    ? 'bg-gray-800 text-gray-300 hover:bg-gray-700'
    : 'bg-gray-900 text-gray-300 hover:bg-gray-800';

  return (
    <button
      onClick={handleClick}
      title={isRecordArmed ? 'Disarm Track' : 'Arm Track for Recording'}
      className={`px-2 py-1 rounded text-sm font-medium transition-colors ${
        mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
      } ${isRecordArmed ? 'bg-red-600 text-white' : inactiveBg} ${className}`}
    >
      <Circle size={14} className={`inline-block ${isRecordArmed ? 'fill-current' : ''}`} />
    </button>
  );
}
