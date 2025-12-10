/**
 * Record Arm Button Component
 * Toggle record arm state for a track
 */

import type { ReactElement } from 'react';
import { Circle } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';

export interface RecordArmButtonProps {
  trackIndex: number;
  className?: string;
}

export function RecordArmButton({
  trackIndex,
  className = '',
}: RecordArmButtonProps): ReactElement {
  const { send } = useReaper();
  const { isRecordArmed, toggleRecordArm } = useTrack(trackIndex);

  const handleClick = () => {
    send(toggleRecordArm());
  };

  return (
    <button
      onClick={handleClick}
      title={isRecordArmed ? 'Disarm Track' : 'Arm Track for Recording'}
      className={`px-2 py-1 rounded text-sm font-medium transition-colors ${
        isRecordArmed
          ? 'bg-red-600 text-white'
          : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
      } ${className}`}
    >
      <Circle size={14} className={`inline-block ${isRecordArmed ? 'fill-current' : ''}`} />
    </button>
  );
}
