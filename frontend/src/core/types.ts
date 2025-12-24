/**
 * REAPER Web Control Types
 * Based on the REAPER HTTP control protocol
 */

// Transport play state values
export type PlayState = 0 | 1 | 2 | 5 | 6;
// 0 = stopped, 1 = playing, 2 = paused, 5 = recording, 6 = record paused

export const PlayStateLabel: Record<PlayState, string> = {
  0: 'stopped',
  1: 'playing',
  2: 'paused',
  5: 'recording',
  6: 'recpaused',
};

// Track flags bitfield
export const TrackFlags = {
  FOLDER: 1,
  SELECTED: 2,
  HAS_FX: 4,
  MUTED: 8,
  SOLOED: 16,
  SOLO_IN_PLACE: 32,
  RECORD_ARMED: 64,
  RECORD_MONITOR_ON: 128,
  RECORD_MONITOR_AUTO: 256,
  TCP_HIDDEN: 512,
  MCP_HIDDEN: 1024,
} as const;

// Transport state from TRANSPORT response
export interface TransportState {
  playState: PlayState;
  positionSeconds: number;
  isRepeat: boolean;
  positionString: string;
  positionBeats: string;
}

// Beat position from BEATPOS response
export interface BeatPosition {
  playState: PlayState;
  positionSeconds: number;
  fullBeatPosition: number;
  measureCount: number;
  beatsInMeasure: number;
  timeSignatureNumerator: number;
  timeSignatureDenominator: number;
}

// Track data from TRACK response
export interface Track {
  index: number;
  name: string;
  flags: number;
  volume: number; // Linear: 0 = -inf, 1 = 0dB, 4 = +12dB
  pan: number; // -1 to 1
  lastMeterPeak: number; // Linear amplitude: 1.0 = 0dB
  lastMeterPos: number; // Linear amplitude: 1.0 = 0dB
  clipped: boolean; // Sticky clip indicator (true if ever exceeded 0dB)
  width: number; // -1 to 1 (stereo width / pan2)
  panMode: number;
  sendCount: number;
  receiveCount: number;
  hwOutCount: number;
  color: number; // 0x01rrggbb format, 0 if no custom color
}

// Helper methods for track flags
export function isMuted(track: Track): boolean {
  return (track.flags & TrackFlags.MUTED) !== 0;
}

export function isSoloed(track: Track): boolean {
  return (track.flags & TrackFlags.SOLOED) !== 0;
}

export function isRecordArmed(track: Track): boolean {
  return (track.flags & TrackFlags.RECORD_ARMED) !== 0;
}

export function isSelected(track: Track): boolean {
  return (track.flags & TrackFlags.SELECTED) !== 0;
}

export function hasFx(track: Track): boolean {
  return (track.flags & TrackFlags.HAS_FX) !== 0;
}

export function getRecordMonitorState(track: Track): 'off' | 'on' | 'auto' {
  if (track.flags & TrackFlags.RECORD_MONITOR_ON) return 'on';
  if (track.flags & TrackFlags.RECORD_MONITOR_AUTO) return 'auto';
  return 'off';
}

// Send/Receive data from SEND response
export interface Send {
  trackIndex: number;
  sendIndex: number; // Positive for sends, negative for receives
  flags: number;
  volume: number;
  pan: number;
  otherTrackIndex: number; // -1 if hardware output
}

export function isSendMuted(send: Send): boolean {
  return (send.flags & 8) !== 0;
}

// Marker data from MARKER response
export interface Marker {
  name: string;
  id: number;
  position: number; // seconds
  color?: number;
}

// Region data from REGION response
export interface Region {
  name: string;
  id: number;
  start: number; // seconds
  end: number; // seconds
  color?: number;
}

// Command state from CMDSTATE response
export interface CommandState {
  commandId: string | number;
  state: number; // >0 = on, 0 = off, -1 = no state
}

// Extended state from EXTSTATE/PROJEXTSTATE response
export interface ExtState {
  section: string;
  key: string;
  value: string;
}

// Union type for all parsed responses
export type ParsedResponse =
  | { type: 'TRANSPORT'; data: TransportState }
  | { type: 'BEATPOS'; data: BeatPosition }
  | { type: 'NTRACK'; count: number }
  | { type: 'TRACK'; data: Track }
  | { type: 'SEND'; data: Send }
  | { type: 'MARKER'; data: Marker }
  | { type: 'REGION'; data: Region }
  | { type: 'MARKER_LIST' }
  | { type: 'MARKER_LIST_END' }
  | { type: 'REGION_LIST' }
  | { type: 'REGION_LIST_END' }
  | { type: 'CMDSTATE'; data: CommandState }
  | { type: 'EXTSTATE'; data: ExtState }
  | { type: 'PROJEXTSTATE'; data: ExtState }
  | { type: 'GET/REPEAT'; value: boolean }
  | { type: 'UNKNOWN'; raw: string };

// Connection status
export interface ConnectionStatus {
  connected: boolean;
  errorCount: number;
  lastError?: string;
}

// Common action command IDs
export const ActionCommands = {
  PLAY: 1007,
  PAUSE: 1008,
  RECORD: 1013,
  STOP_SAVE: 1016,
  STOP: 40667,
  ABORT_RECORDING: 40668,
  PREV_MARKER: 40172,
  NEXT_MARKER: 40173,
  TOGGLE_METRONOME: 40364,
  TOGGLE_REPEAT: 1068,
  TAP_TEMPO: 1134,
  AUTO_PUNCH: 40076,
} as const;

// SWS extension action IDs (string-based, stable across sessions)
export const SWSCommands = {
  COUNT_IN_RECORD: '_SWS_AWCOUNTRECTOG',
  COUNT_IN_PLAYBACK: '_SWS_AWCOUNTPLAYTOG',
} as const;
