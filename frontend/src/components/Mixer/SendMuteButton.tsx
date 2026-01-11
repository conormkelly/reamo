/**
 * SendMuteButton Component
 * Mute button for a track's send to a specific destination.
 * Shows amber color scheme to match Sends mode.
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useSends } from '../../hooks/useSends';
import { send } from '../../core/WebSocketCommands';

export interface SendMuteButtonProps {
  /** Source track index */
  trackIndex: number;
  /** Destination track index */
  destTrackIdx: number;
  /** Whether parent track is selected */
  isSelected?: boolean;
  className?: string;
}

export function SendMuteButton({
  trackIndex,
  destTrackIdx,
  isSelected = false,
  className = '',
}: SendMuteButtonProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const { getSendByDestination } = useSends();

  const sendSlot = getSendByDestination(trackIndex, destTrackIdx);
  const hasSend = !!sendSlot;
  const isMuted = sendSlot?.muted ?? false;
  const sendIndex = sendSlot?.sendIndex ?? 0;

  const handleClick = () => {
    if (!hasSend) return;
    sendCommand(send.setMute(trackIndex, sendIndex, isMuted ? 0 : 1));
  };

  // Base styles
  const baseStyles = 'w-8 h-6 text-xs font-bold rounded transition-colors';

  // State-dependent styles
  const stateStyles = !hasSend
    ? 'bg-bg-disabled text-text-disabled cursor-default opacity-30'
    : isMuted
      ? 'bg-sends-hover text-white'
      : isSelected
        ? 'bg-bg-disabled text-text-secondary hover:bg-bg-elevated'
        : 'bg-bg-elevated text-text-secondary hover:bg-bg-surface';

  return (
    <button
      onClick={handleClick}
      disabled={!hasSend}
      className={`${baseStyles} ${stateStyles} ${className}`}
      title={!hasSend ? 'No send to this destination' : isMuted ? 'Unmute send' : 'Mute send'}
    >
      M
    </button>
  );
}
