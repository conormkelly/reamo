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
  /** Whether parent track is selected (affects background) */
  isSelected?: boolean;
}

export function MuteButton({
  trackIndex,
  className = '',
  isSelected = false,
}: MuteButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isMuted, toggleMute } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  const handleClick = () => {
    if (mixerLocked) return;
    sendCommand(toggleMute());
  };

  // Buttons always darker than track background for contrast
  const inactiveBg = isSelected
    ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
    : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';

  return (
    <button
      onClick={handleClick}
      aria-pressed={isMuted}
      title={isMuted ? 'Unmute Track' : 'Mute Track'}
      className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
        mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
      } ${isMuted ? 'bg-primary-hover text-text-on-primary' : inactiveBg} ${className}`}
    >
      M
    </button>
  );
}
