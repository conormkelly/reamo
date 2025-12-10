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
import * as commands from '../core/CommandBuilder';
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
  panString: string;
  isMuted: boolean;
  isSoloed: boolean;
  isRecordArmed: boolean;
  isSelected: boolean;
  hasFx: boolean;
  recordMonitorState: 'off' | 'on' | 'auto';
  color: string | null;
  textColor: 'black' | 'white';

  // Command builders (return command strings)
  toggleMute: () => string;
  toggleSolo: () => string;
  toggleRecordArm: () => string;
  toggleSelect: () => string;
  cycleRecordMonitor: () => string;
  setVolume: (linearVolume: number) => string;
  setVolumeRelative: (dbChange: number) => string;
  setFaderPosition: (position: number) => string;
  setPan: (pan: number) => string;
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
        panString: 'center',
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
      panString: panToString(track.pan),
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

  // Command builders
  const toggleMute = useCallback(
    () => commands.join(commands.setMute(trackIndex), commands.track(trackIndex)),
    [trackIndex]
  );

  const toggleSolo = useCallback(
    () => commands.join(commands.setSolo(trackIndex), commands.track(trackIndex)),
    [trackIndex]
  );

  const toggleRecordArm = useCallback(
    () =>
      commands.join(commands.setRecordArm(trackIndex), commands.track(trackIndex)),
    [trackIndex]
  );

  const toggleSelect = useCallback(
    () =>
      commands.join(commands.setSelection(trackIndex), commands.track(trackIndex)),
    [trackIndex]
  );

  const cycleRecordMonitor = useCallback(
    () =>
      commands.join(
        commands.setRecordMonitor(trackIndex),
        commands.track(trackIndex)
      ),
    [trackIndex]
  );

  const setVolume = useCallback(
    (linearVolume: number) =>
      commands.join(
        commands.setVolume(trackIndex, linearVolume),
        commands.track(trackIndex)
      ),
    [trackIndex]
  );

  const setVolumeRelative = useCallback(
    (dbChange: number) => {
      const prefix = dbChange >= 0 ? '+' : '';
      return commands.join(
        commands.setVolume(trackIndex, `${prefix}${dbChange}`),
        commands.track(trackIndex)
      );
    },
    [trackIndex]
  );

  const setFaderPosition = useCallback(
    (position: number) => {
      const linearVolume = faderToVolume(position);
      return commands.join(
        commands.setVolume(trackIndex, linearVolume),
        commands.track(trackIndex)
      );
    },
    [trackIndex]
  );

  const setPan = useCallback(
    (pan: number) =>
      commands.join(
        commands.setPan(trackIndex, pan),
        commands.track(trackIndex)
      ),
    [trackIndex]
  );

  return {
    track,
    exists: track !== null,
    ...derived,
    toggleMute,
    toggleSolo,
    toggleRecordArm,
    toggleSelect,
    cycleRecordMonitor,
    setVolume,
    setVolumeRelative,
    setFaderPosition,
    setPan,
  };
}
