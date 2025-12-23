/**
 * Mute Button Component
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';

export interface MuteButtonProps {
  trackIndex: number;
  className?: string;
}

export function MuteButton({
  trackIndex,
  className = '',
}: MuteButtonProps): ReactElement {
  const { send } = useReaper();
  const { isMuted, toggleMute } = useTrack(trackIndex);

  const handleClick = () => {
    send(toggleMute());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
        isMuted
          ? 'bg-blue-500 text-white'
          : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
      } ${className}`}
    >
      {isMuted ? 'M' : 'M'}
    </button>
  );
}
