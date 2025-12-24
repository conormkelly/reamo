/**
 * Mute Button Component
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';

export interface MuteButtonProps {
  trackIndex: number;
  className?: string;
}

export function MuteButton({
  trackIndex,
  className = '',
}: MuteButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isMuted, toggleMute } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  const handleClick = () => {
    if (mixerLocked) return;
    sendCommand(toggleMute());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
        mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
      } ${
        isMuted
          ? 'bg-blue-500 text-white'
          : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
      } ${className}`}
    >
      M
    </button>
  );
}
