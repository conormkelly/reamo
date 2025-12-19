/**
 * REAPER Command Builder
 * Type-safe construction of REAPER HTTP API commands
 */

import { ActionCommands } from './types';

/**
 * Build a command to get transport state
 */
export function transport(): string {
  return 'TRANSPORT';
}

/**
 * Build a command to get beat position
 */
export function beatPos(): string {
  return 'BEATPOS';
}

/**
 * Build a command to get track count
 */
export function trackCount(): string {
  return 'NTRACK';
}

/**
 * Build a command to get all tracks
 */
export function allTracks(): string {
  return 'TRACK';
}

/**
 * Build a command to get a single track
 */
export function track(index: number): string {
  return `TRACK/${index}`;
}

/**
 * Build a command to get a range of tracks
 */
export function trackRange(start: number, end: number): string {
  return `TRACK/${start}-${end}`;
}

/**
 * Build a command to get markers
 */
export function markers(): string {
  return 'MARKER';
}

/**
 * Build a command to get regions
 */
export function regions(): string {
  return 'REGION';
}

/**
 * Build a command to get repeat state
 */
export function getRepeat(): string {
  return 'GET/REPEAT';
}

/**
 * Build a command to get command state (e.g., metronome toggle)
 */
export function getCommandState(commandId: number | string): string {
  return `GET/${commandId}`;
}

/**
 * Build a command to get a track property
 */
export function getTrackProperty(trackIndex: number, property: string): string {
  return `GET/TRACK/${trackIndex}/${property}`;
}

/**
 * Build a command to get send/receive info
 */
export function getSend(trackIndex: number, sendIndex: number): string {
  return `GET/TRACK/${trackIndex}/SEND/${sendIndex}`;
}

/**
 * Build a command to get extended state
 */
export function getExtState(section: string, key: string): string {
  return `GET/EXTSTATE/${encodeURIComponent(section)}/${encodeURIComponent(key)}`;
}

/**
 * Build a command to get project extended state
 */
export function getProjExtState(section: string, key: string): string {
  return `GET/PROJEXTSTATE/${encodeURIComponent(section)}/${encodeURIComponent(key)}`;
}

// SET Commands

/**
 * Build a command to set track volume
 * @param trackIndex - Track index (0 = master)
 * @param value - Absolute (0-4) or relative ("+2" / "-2" for dB adjustment)
 * @param ignoreGanging - If true, ignores track ganging
 */
export function setVolume(
  trackIndex: number,
  value: number | string,
  ignoreGanging = false
): string {
  const suffix = ignoreGanging ? 'g' : '';
  return `SET/TRACK/${trackIndex}/VOL/${value}${suffix}`;
}

/**
 * Build a command to set track pan
 * @param trackIndex - Track index (0 = master)
 * @param value - Absolute (-1 to 1) or relative ("+0.1" / "-0.1")
 * @param ignoreGanging - If true, ignores track ganging
 */
export function setPan(
  trackIndex: number,
  value: number | string,
  ignoreGanging = false
): string {
  const suffix = ignoreGanging ? 'g' : '';
  return `SET/TRACK/${trackIndex}/PAN/${value}${suffix}`;
}

/**
 * Build a command to set track width
 * @param trackIndex - Track index (0 = master)
 * @param value - Absolute (-1 to 1) or relative
 * @param ignoreGanging - If true, ignores track ganging
 */
export function setWidth(
  trackIndex: number,
  value: number | string,
  ignoreGanging = false
): string {
  const suffix = ignoreGanging ? 'g' : '';
  return `SET/TRACK/${trackIndex}/WIDTH/${value}${suffix}`;
}

/**
 * Build a command to set track mute
 * @param trackIndex - Track index (0 = master)
 * @param value - 1 = on, 0 = off, -1 = toggle
 */
export function setMute(trackIndex: number, value: 1 | 0 | -1 = -1): string {
  return `SET/TRACK/${trackIndex}/MUTE/${value}`;
}

/**
 * Build a command to set track solo
 * @param trackIndex - Track index (0 = master)
 * @param value - 1 = on, 0 = off, -1 = toggle
 */
export function setSolo(trackIndex: number, value: 1 | 0 | -1 = -1): string {
  return `SET/TRACK/${trackIndex}/SOLO/${value}`;
}

/**
 * Build a command to set track FX enabled
 * @param trackIndex - Track index (0 = master)
 * @param value - 1 = on, 0 = off, -1 = toggle
 */
export function setFx(trackIndex: number, value: 1 | 0 | -1 = -1): string {
  return `SET/TRACK/${trackIndex}/FX/${value}`;
}

/**
 * Build a command to set track record arm
 * @param trackIndex - Track index (0 = master)
 * @param value - 1 = on, 0 = off, -1 = toggle
 */
export function setRecordArm(trackIndex: number, value: 1 | 0 | -1 = -1): string {
  return `SET/TRACK/${trackIndex}/RECARM/${value}`;
}

/**
 * Build a command to set track record monitoring
 * @param trackIndex - Track index (0 = master)
 * @param value - -1 = cycle, 1 = on, 2 = auto, 0 = off
 */
export function setRecordMonitor(
  trackIndex: number,
  value: -1 | 0 | 1 | 2 = -1
): string {
  return `SET/TRACK/${trackIndex}/RECMON/${value}`;
}

/**
 * Build a command to set track selection
 * @param trackIndex - Track index (0 = master)
 * @param value - 1 = select, 0 = deselect, -1 = toggle
 */
export function setSelection(trackIndex: number, value: 1 | 0 | -1 = -1): string {
  return `SET/TRACK/${trackIndex}/SEL/${value}`;
}

/**
 * Build a command to set position in seconds
 */
export function setPosition(seconds: number): string {
  return `SET/POS/${seconds}`;
}

/**
 * Build a command to set position by string
 * Supports: "r1" (region ID 1), "m1" (marker ID 1), "R1" (first timeline region), "M1" (first timeline marker)
 */
export function setPositionString(positionString: string): string {
  return `SET/POS_STR/${encodeURIComponent(positionString)}`;
}

/**
 * Build a command to set repeat
 * @param value - 1 = on, 0 = off, -1 = toggle
 */
export function setRepeat(value: 1 | 0 | -1 = -1): string {
  return `SET/REPEAT/${value}`;
}

/**
 * Build a command to set send/receive volume
 */
export function setSendVolume(
  trackIndex: number,
  sendIndex: number,
  value: number,
  mode: '' | 'e' | 'E' = ''
): string {
  return `SET/TRACK/${trackIndex}/SEND/${sendIndex}/VOL/${value}${mode}`;
}

/**
 * Build a command to set send/receive pan
 */
export function setSendPan(
  trackIndex: number,
  sendIndex: number,
  value: number,
  mode: '' | 'e' | 'E' = ''
): string {
  return `SET/TRACK/${trackIndex}/SEND/${sendIndex}/PAN/${value}${mode}`;
}

/**
 * Build a command to set send/receive mute
 */
export function setSendMute(
  trackIndex: number,
  sendIndex: number,
  value: 1 | 0 | -1 = -1
): string {
  return `SET/TRACK/${trackIndex}/SEND/${sendIndex}/MUTE/${value}`;
}

/**
 * Build a command to set extended state
 */
export function setExtState(section: string, key: string, value: string): string {
  return `SET/EXTSTATE/${encodeURIComponent(section)}/${encodeURIComponent(key)}/${encodeURIComponent(value)}`;
}

/**
 * Build a command to set persistent extended state
 */
export function setExtStatePersist(
  section: string,
  key: string,
  value: string
): string {
  return `SET/EXTSTATEPERSIST/${encodeURIComponent(section)}/${encodeURIComponent(key)}/${encodeURIComponent(value)}`;
}

/**
 * Build a command to set project extended state
 */
export function setProjExtState(
  section: string,
  key: string,
  value: string
): string {
  return `SET/PROJEXTSTATE/${encodeURIComponent(section)}/${encodeURIComponent(key)}/${encodeURIComponent(value)}`;
}

/**
 * Build a command to add an undo point
 */
export function setUndo(message: string): string {
  return `SET/UNDO/${encodeURIComponent(message)}`;
}

/**
 * Build a command to begin an undo block
 */
export function undoBegin(): string {
  return 'SET/UNDO_BEGIN';
}

/**
 * Build a command to end an undo block
 */
export function undoEnd(message: string): string {
  return `SET/UNDO_END/${encodeURIComponent(message)}`;
}

// Action Commands (convenience wrappers)

/**
 * Build a play command
 */
export function play(): string {
  return String(ActionCommands.PLAY);
}

/**
 * Build a pause command
 */
export function pause(): string {
  return String(ActionCommands.PAUSE);
}

/**
 * Build a stop command
 */
export function stop(): string {
  return String(ActionCommands.STOP);
}

/**
 * Build a stop and save command
 */
export function stopSave(): string {
  return String(ActionCommands.STOP_SAVE);
}

/**
 * Build a record command
 */
export function record(): string {
  return String(ActionCommands.RECORD);
}

/**
 * Build an abort recording command
 */
export function abortRecording(): string {
  return String(ActionCommands.ABORT_RECORDING);
}

/**
 * Build a previous marker command
 */
export function prevMarker(): string {
  return String(ActionCommands.PREV_MARKER);
}

/**
 * Build a next marker command
 */
export function nextMarker(): string {
  return String(ActionCommands.NEXT_MARKER);
}

/**
 * Build a toggle metronome command
 */
export function toggleMetronome(): string {
  return String(ActionCommands.TOGGLE_METRONOME);
}

/**
 * Build a toggle repeat command
 */
export function toggleRepeat(): string {
  return String(ActionCommands.TOGGLE_REPEAT);
}

/**
 * Build a tap tempo command
 */
export function tapTempo(): string {
  return String(ActionCommands.TAP_TEMPO);
}

/**
 * Build a set tempo command (requires REAPER 6.13+)
 * @param bpm - Tempo in BPM (2-960)
 */
export function setTempo(bpm: number): string {
  const clampedBpm = Math.max(2, Math.min(960, Math.round(bpm)));
  return `OSC/tempo%2Fraw:${clampedBpm}`;
}

/**
 * Build a set metronome volume command
 * Uses action 999 (Set metronome volume) via OSC CC
 * @param volume - Volume level 0.0 to 1.0
 * Note: No feedback available from REAPER - UI must maintain local state
 */
export function setMetronomeVolume(volume: number): string {
  const clampedVolume = Math.max(0, Math.min(1, volume));
  return `OSC/action%2F999%2Fcc:${clampedVolume}`;
}

/**
 * Build a custom action command by ID
 */
export function action(commandId: number | string): string {
  return String(commandId);
}

// Take switching commands

/**
 * Select all items on selected tracks in current time selection
 * Action 40718: "Item: Select all items on selected tracks in current time selection"
 */
export function selectItemsInTimeSelection(): string {
  return '40718';
}

/**
 * Switch selected items to next take
 * Action 42611: "Take: Switch items to next take"
 */
export function nextTake(): string {
  return '42611';
}

/**
 * Switch selected items to previous take
 * Action 42612: "Take: Switch items to previous take"
 */
export function previousTake(): string {
  return '42612';
}

/**
 * Unselect all items
 * Action 40289: "Item: Unselect (clear selection of) all items"
 */
export function unselectAllItems(): string {
  return '40289';
}

/**
 * Join multiple commands with semicolons
 */
export function join(...commands: string[]): string {
  return commands.join(';');
}
