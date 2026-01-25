/**
 * Mute Button Component
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';
import {
  getInactiveClasses,
  getLockedClasses,
  trackControlBaseClasses,
} from './trackControlStyles';

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

  const inactiveBg = getInactiveClasses(isSelected);
  const lockedClasses = getLockedClasses(mixerLocked);

  return (
    <button
      onClick={handleClick}
      aria-pressed={isMuted}
      title={isMuted ? 'Unmute Track' : 'Mute Track'}
      className={`px-3 py-1 ${trackControlBaseClasses} ${lockedClasses} ${
        isMuted ? 'bg-primary-hover text-text-on-primary' : inactiveBg
      } ${className}`}
    >
      M
    </button>
  );
}
