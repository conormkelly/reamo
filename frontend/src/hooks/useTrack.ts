/**
 * Single Track Hook
 * Provides state and controls for a specific track
 */

import { useCallback, useMemo } from 'react';
import { useReaperStore } from '../store';
import type { Track } from '../core/types';
import {
  isMuted,
  isSoloed,
  isRecordArmed,
  isSelected,
  hasFx,
  getRecordMonitorState,
} from '../core/types';
import { track as trackCmd } from '../core/WebSocketCommands';
import type { WSCommand } from '../core/WebSocketCommands';
import { volumeToDbString, volumeToFader, faderToVolume } from '../utils/volume';
import { panToString } from '../utils/pan';
import { reaperColorToHex, getContrastColor } from '../utils/color';

export interface UseTrackReturn {
  // Track data (null if track doesn't exist)
  track: Track | null;
  exists: boolean;

  // Derived state
  name: string;
  volumeDb: string;
  faderPosition: number;
  pan: number;
  panDisplay: string;
  isMuted: boolean;
  isSoloed: boolean;
  isRecordArmed: boolean;
  isSelected: boolean;
  hasFx: boolean;
  recordMonitorState: 'off' | 'on' | 'auto';
  color: string | null;
  textColor: 'black' | 'white';

  // Command builders (return WSCommand objects)
  toggleMute: () => WSCommand;
  toggleSolo: () => WSCommand;
  toggleRecordArm: () => WSCommand;
  cycleRecordMonitor: () => WSCommand;
  setVolume: (linearVolume: number) => WSCommand;
  setFaderPosition: (position: number) => WSCommand;
  setPan: (pan: number) => WSCommand;
}

/**
 * Hook for a single track's state and controls
 * @param trackIndex - Track index (0 = master, 1+ = user tracks)
 */
export function useTrack(trackIndex: number): UseTrackReturn {
  const track = useReaperStore((state) => state.tracks[trackIndex] ?? null);

  // Derived state with memoization
  const derived = useMemo(() => {
    if (!track) {
      return {
        name: '',
        volumeDb: '-inf dB',
        faderPosition: 0,
        pan: 0,
        panDisplay: 'center',
        isMuted: false,
        isSoloed: false,
        isRecordArmed: false,
        isSelected: false,
        hasFx: false,
        recordMonitorState: 'off' as const,
        color: null,
        textColor: 'white' as const,
      };
    }

    return {
      name: track.name,
      volumeDb: volumeToDbString(track.volume),
      faderPosition: volumeToFader(track.volume),
      pan: track.pan,
      panDisplay: panToString(track.pan),
      isMuted: isMuted(track),
      isSoloed: isSoloed(track),
      isRecordArmed: isRecordArmed(track),
      isSelected: isSelected(track),
      hasFx: hasFx(track),
      recordMonitorState: getRecordMonitorState(track),
      color: reaperColorToHex(track.color),
      textColor: getContrastColor(track.color),
    };
  }, [track]);

  // Command builders - return WSCommand objects for use with sendCommand
  const toggleMute = useCallback(
    () => trackCmd.setMute(trackIndex), // No value = toggle
    [trackIndex]
  );

  const toggleSolo = useCallback(
    () => trackCmd.setSolo(trackIndex), // No value = toggle
    [trackIndex]
  );

  const toggleRecordArm = useCallback(
    () => trackCmd.setRecArm(trackIndex), // No value = toggle
    [trackIndex]
  );

  const cycleRecordMonitor = useCallback(
    () => trackCmd.setRecMon(trackIndex), // No value = cycle
    [trackIndex]
  );

  const setVolume = useCallback(
    (linearVolume: number) => trackCmd.setVolume(trackIndex, linearVolume),
    [trackIndex]
  );

  const setFaderPosition = useCallback(
    (position: number) => {
      const linearVolume = faderToVolume(position);
      return trackCmd.setVolume(trackIndex, linearVolume);
    },
    [trackIndex]
  );

  const setPan = useCallback(
    (pan: number) => trackCmd.setPan(trackIndex, pan),
    [trackIndex]
  );

  return {
    track,
    exists: track !== null,
    ...derived,
    toggleMute,
    toggleSolo,
    toggleRecordArm,
    cycleRecordMonitor,
    setVolume,
    setFaderPosition,
    setPan,
  };
}
