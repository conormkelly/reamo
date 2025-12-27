/**
 * Solo Button Component
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';

export interface SoloButtonProps {
  trackIndex: number;
  className?: string;
  /** Whether parent track is selected (affects background) */
  isSelected?: boolean;
}

export function SoloButton({
  trackIndex,
  className = '',
  isSelected = false,
}: SoloButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isSoloed, toggleSolo } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  const handleClick = () => {
    if (mixerLocked) return;
    sendCommand(toggleSolo());
  };

  // Buttons always darker than track background for contrast
  const inactiveBg = isSelected
    ? 'bg-gray-800 text-gray-300 hover:bg-gray-700'
    : 'bg-gray-900 text-gray-300 hover:bg-gray-800';

  return (
    <button
      onClick={handleClick}
      className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
        mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
      } ${isSoloed ? 'bg-yellow-500 text-black' : inactiveBg} ${className}`}
    >
      S
    </button>
  );
}
