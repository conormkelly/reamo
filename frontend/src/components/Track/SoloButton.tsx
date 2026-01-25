/**
 * Solo Button Component
 *
 * Tap: Toggle solo on/off
 * Long-press: Exclusive solo (unsolo all others, solo this track)
 */

import { useCallback, type ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';
import { useLongPress } from '../../hooks';
import { track as trackCmd } from '../../core/WebSocketCommands';
import {
  getInactiveClasses,
  getLockedClasses,
  trackControlBaseClasses,
} from './trackControlStyles';

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
  const { isSoloed, toggleSolo, guid } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  // Normal tap: toggle solo
  const handleTap = useCallback(() => {
    if (mixerLocked) return;
    sendCommand(toggleSolo());
  }, [mixerLocked, sendCommand, toggleSolo]);

  // Long-press: exclusive solo (unsolo all, then solo this track)
  const handleLongPress = useCallback(() => {
    if (mixerLocked) return;
    // Single atomic command - backend handles undo block
    sendCommand(trackCmd.setSoloExclusive(trackIndex, guid ?? undefined));
  }, [mixerLocked, sendCommand, trackIndex, guid]);

  const { handlers } = useLongPress({
    onTap: handleTap,
    onLongPress: handleLongPress,
    duration: 400, // Slightly faster than default for responsiveness
  });

  const inactiveBg = getInactiveClasses(isSelected);
  const lockedClasses = getLockedClasses(mixerLocked);

  return (
    <button
      {...handlers}
      aria-pressed={isSoloed}
      title={isSoloed ? 'Unsolo Track' : 'Solo Track (hold for exclusive)'}
      className={`px-3 py-1 ${trackControlBaseClasses} touch-none ${lockedClasses} ${
        isSoloed ? 'bg-solo text-solo-text' : inactiveBg
      } ${className}`}
    >
      S
    </button>
  );
}
