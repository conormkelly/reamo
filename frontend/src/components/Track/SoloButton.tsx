/**
 * Solo Button Component
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';

export interface SoloButtonProps {
  trackIndex: number;
  className?: string;
}

export function SoloButton({
  trackIndex,
  className = '',
}: SoloButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isSoloed, toggleSolo } = useTrack(trackIndex);

  const handleClick = () => {
    sendCommand(toggleSolo());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
        isSoloed
          ? 'bg-yellow-500 text-black'
          : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
      } ${className}`}
    >
      S
    </button>
  );
}
