/**
 * Single Track Hook
 * Provides state and controls for a specific track
 *
 * @example
 * ```tsx
 * function TrackStrip({ trackIndex }: { trackIndex: number }) {
 *   const { sendCommand } = useReaper();
 *   const { name, volumeDb, isMuted, toggleMute, setFaderPosition } = useTrack(trackIndex);
 *
 *   return (
 *     <div>
 *       <span>{name}</span>
 *       <span>{volumeDb}</span>
 *       <button onClick={() => sendCommand(toggleMute())}>{isMuted ? 'M' : 'm'}</button>
 *       <Fader onChange={(pos) => sendCommand(setFaderPosition(pos))} />
 *     </div>
 *   );
 * }
 * ```
 */

import { useCallback, useMemo } from 'react';
import { useReaperStore } from '../store';
import type { Track } from '../core/types';
import {
  isMuted,
  isSoloed,
  isRecordArmed,
  isSelected,
  isFxDisabled,
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

  // Track GUID for stable targeting (use during gestures to avoid reordering issues)
  guid: string | undefined;

  // Raw I_RECINPUT value (only present when track is record-armed)
  recInput: number | undefined;

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
  fxCount: number;
  isFxDisabled: boolean;
  recordMonitorState: 'off' | 'on' | 'auto';
  color: string | null;
  textColor: 'black' | 'white';

  // Command builders (return WSCommand objects)
  // Toggle commands use GUID when available for stability
  toggleMute: () => WSCommand;
  toggleSolo: () => WSCommand;
  toggleRecordArm: () => WSCommand;
  cycleRecordMonitor: () => WSCommand;
  // Continuous control commands ALWAYS use GUID when available
  setVolume: (linearVolume: number) => WSCommand;
  setFaderPosition: (position: number) => WSCommand;
  setPan: (pan: number) => WSCommand;
}

/**
 * Hook for a single track's state and controls
 * @param trackIndex - Track index (0 = master, 1+ = user tracks)
 */
export function useTrack(trackIndex: number): UseTrackReturn {
  // Defensive selector - state can be undefined briefly on mobile during hydration
  const track = useReaperStore((state) => state?.tracks?.[trackIndex] ?? null);

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
        fxCount: 0,
        isFxDisabled: false,
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
      fxCount: track.fxCount,
      isFxDisabled: isFxDisabled(track),
      recordMonitorState: getRecordMonitorState(track),
      color: reaperColorToHex(track.color),
      textColor: getContrastColor(track.color),
    };
  }, [track]);

  // Get GUID for stable targeting
  const guid = track?.guid;

  // Command builders - return WSCommand objects for use with sendCommand
  // All commands include GUID when available for stability during track reordering
  const toggleMute = useCallback(
    () => trackCmd.setMute(trackIndex, undefined, guid), // No value = toggle
    [trackIndex, guid]
  );

  const toggleSolo = useCallback(
    () => trackCmd.setSolo(trackIndex, undefined, guid), // No value = toggle
    [trackIndex, guid]
  );

  const toggleRecordArm = useCallback(
    () => trackCmd.setRecArm(trackIndex, undefined, guid), // No value = toggle
    [trackIndex, guid]
  );

  const cycleRecordMonitor = useCallback(
    () => trackCmd.setRecMon(trackIndex, undefined, guid), // No value = cycle
    [trackIndex, guid]
  );

  const setVolume = useCallback(
    (linearVolume: number) => trackCmd.setVolume(trackIndex, linearVolume, guid),
    [trackIndex, guid]
  );

  const setFaderPosition = useCallback(
    (position: number) => {
      const linearVolume = faderToVolume(position);
      return trackCmd.setVolume(trackIndex, linearVolume, guid);
    },
    [trackIndex, guid]
  );

  const setPan = useCallback(
    (pan: number) => trackCmd.setPan(trackIndex, pan, guid),
    [trackIndex, guid]
  );

  return {
    track,
    exists: track !== null,
    guid,
    recInput: track?.recInput,
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
