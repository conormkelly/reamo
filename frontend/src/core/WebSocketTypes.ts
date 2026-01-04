/**
 * WebSocket API Types
 * Based on extension/API.md protocol specification
 */

// =============================================================================
// Protocol Messages
// =============================================================================

/** Base message types */
export type MessageType = 'hello' | 'command' | 'response' | 'event' | 'clockSync' | 'clockSyncResponse';

/** Hello handshake (client → server) */
export interface HelloMessage {
  type: 'hello';
  clientVersion: string;
  protocolVersion: number;
  token?: string;
}

/** Hello response (server → client) */
export interface HelloResponse {
  type: 'hello';
  extensionVersion: string;
  protocolVersion: number;
  htmlMtime?: number; // For hot reload detection on reconnect
}

/** Command message (client → server) */
export interface CommandMessage {
  type: 'command';
  command: string;
  id?: string;
  [key: string]: unknown; // Additional parameters
}

/** Clock sync request (client → server) */
export interface ClockSyncMessage {
  type: 'clockSync';
  t0: number; // Client send time in ms
}

/** Clock sync response (server → client) */
export interface ClockSyncResponse {
  type: 'clockSyncResponse';
  t0: number; // Echoed client send time
  t1: number; // Server receive time in ms
  t2: number; // Server send time in ms
}

/** Response message (server → client) */
export interface ResponseMessage {
  type: 'response';
  id: string;
  success: boolean;
  payload?: Record<string, unknown>;
  error?: {
    code: string;
    message: string;
  };
}

/** Event message (server → client, broadcast) */
export interface EventMessage {
  type: 'event';
  event: EventType;
  payload?: EventPayload; // Optional for events like 'reload' that have no payload
}

export type EventType = 'transport' | 'tt' | 'project' | 'tracks' | 'markers' | 'regions' | 'items' | 'reload' | 'actionToggleState' | 'tempoMap' | 'projectNotesChanged' | 'playlist';

export type EventPayload =
  | TransportEventPayload
  | TransportTickEventPayload
  | ProjectEventPayload
  | TracksEventPayload
  | MarkersEventPayload
  | RegionsEventPayload
  | ItemsEventPayload
  | ActionToggleStateEventPayload
  | TempoMapEventPayload
  | ProjectNotesChangedEventPayload
  | PlaylistEventPayload;

/** Lightweight transport tick event (position updates during playback) */
export interface TransportTickEventPayload {
  p: number; // Position in seconds (for time display, critical for seeks)
  t: number; // Server timestamp in ms
  b: number; // Beat position (quarter notes from project start)
  bpm: number; // Quarter-note BPM (for prediction math)
  ts: [number, number]; // Time signature [numerator, denominator]
  bbt: string; // Pre-computed bar.beat.ticks (e.g., "12.3.48")
}

/** Any message from server */
export type ServerMessage = HelloResponse | ResponseMessage | EventMessage | ClockSyncResponse;

// =============================================================================
// Transport Event
// =============================================================================

export type PlayState = 0 | 1 | 2 | 5 | 6;
// 0 = stopped, 1 = playing, 2 = paused, 5 = recording, 6 = record paused

export interface TransportEventPayload {
  playState: PlayState;
  position: number; // seconds (play position if playing, cursor if stopped)
  positionBeats: string; // "bar.beat.ticks" format
  cursorPosition: number; // edit cursor position in seconds
  bpm: number;
  timeSignature: {
    numerator: number;
    denominator: number;
  };
  timeSelection: {
    start: number;
    end: number;
  };
  // Transport sync fields (Phase 1)
  t?: number; // Server timestamp in ms (high-precision)
  b?: number; // Raw beat position (total beats from project start)
  // Note: repeat, metronome, projectLength, barOffset moved to ProjectEventPayload
}

// =============================================================================
// Project Event (undo/redo state + project-level settings)
// =============================================================================

export interface ProjectEventPayload {
  canUndo: string | null; // Description of next undo action, or null
  canRedo: string | null; // Description of next redo action, or null
  stateChangeCount: number; // Counter for change detection
  // Project-level settings (moved from transport for efficiency)
  repeat: boolean;
  metronome: {
    enabled: boolean;
    volume: number; // linear 0-4
    volumeDb: number; // dB
  };
  master: {
    stereoEnabled: boolean; // true = stereo, false = mono (L+R summed)
  };
  projectLength: number; // seconds
  barOffset: number; // bar offset (e.g., -4 means time 0 = bar 1, display starts at bar -4)
  isDirty: boolean; // Project has unsaved changes
}

// =============================================================================
// Tracks Event
// =============================================================================

export interface WSTrack {
  idx: number;
  name: string;
  color: number; // Native OS color, 0 = default
  volume: number; // Linear: 1.0 = 0dB
  pan: number; // -1 to 1
  mute: boolean;
  solo: number; // 0 = off, 1 = solo, 2 = solo in place
  recArm: boolean;
  recMon: number; // 0 = off, 1 = on, 2 = not when playing
  fxEnabled: boolean;
  selected: boolean;
}

export interface WSMeter {
  trackIdx: number;
  peakL: number; // 0-1+, 1.0 = 0dB
  peakR: number;
  clipped: boolean; // sticky until cleared
}

export interface TracksEventPayload {
  tracks: WSTrack[];
  meters: WSMeter[];
}

// =============================================================================
// Markers Event
// =============================================================================

export interface WSMarker {
  id: number;
  position: number; // seconds
  positionBeats: number; // position in beats (tempo-aware)
  positionBars: string; // "bar.beat.ticks" format
  name: string;
  color: number; // Native OS color, 0 = default
}

export interface MarkersEventPayload {
  markers: WSMarker[];
}

// =============================================================================
// Regions Event
// =============================================================================

export interface WSRegion {
  id: number;
  start: number; // seconds
  end: number; // seconds
  startBeats: number; // start position in beats (tempo-aware)
  endBeats: number; // end position in beats (tempo-aware)
  startBars: string; // "bar.beat.ticks" format
  endBars: string; // "bar.beat.ticks" format
  lengthBars: string; // "bar.beat.ticks" format (tempo-aware duration)
  name: string;
  color: number; // Native OS color, 0 = default
}

export interface RegionsEventPayload {
  regions: WSRegion[];
}

// =============================================================================
// Items Event
// =============================================================================

export interface WSTake {
  name: string;
  guid: string; // Stable identifier for caching
  isActive: boolean;
  isMIDI: boolean; // If true, skip peaks request
}

export interface WSItem {
  guid: string; // Stable identifier for caching
  trackIdx: number;
  itemIdx: number;
  position: number; // seconds
  length: number; // seconds
  color: number;
  locked: boolean;
  selected: boolean;
  activeTakeIdx: number;
  notes: string;
  takes: WSTake[];
}

export interface ItemsEventPayload {
  items: WSItem[];
  // Note: timeSelection is in TransportEventPayload, not here
}

// =============================================================================
// Action Toggle State Event
// =============================================================================

/** Toggle state changes broadcast (sparse delta) */
export interface ActionToggleStateEventPayload {
  changes: Record<string, number>; // commandId → state (-1, 0, or 1)
}

// =============================================================================
// Tempo Map Event
// =============================================================================

/** Individual tempo marker */
export interface WSTempoMarker {
  position: number; // seconds
  positionBeats: number; // beat position (total beats from project start)
  bpm: number;
  timesigNum: number;
  timesigDenom: number;
  linear: boolean; // linear tempo ramp to next marker
}

/** Tempo map broadcast */
export interface TempoMapEventPayload {
  markers: WSTempoMarker[];
}

/** Project notes changed event (broadcast to subscribers when notes change externally) */
export interface ProjectNotesChangedEventPayload {
  hash: string; // New hash of notes content (hex string)
}

// =============================================================================
// Playlist Event
// =============================================================================

/** Single entry in a playlist */
export interface WSPlaylistEntry {
  regionId: number; // References region.id from regions event
  loopCount: number; // -1 = infinite, 0 = skip, 1+ = times to play
  deleted?: boolean; // true if referenced region was deleted (absent if valid)
}

/** A playlist containing ordered entries */
export interface WSPlaylist {
  name: string;
  entries: WSPlaylistEntry[];
  stopAfterLast: boolean; // Stop transport after final entry completes
}

/** Playlist state broadcast (5Hz) */
export interface PlaylistEventPayload {
  playlists: WSPlaylist[];
  activePlaylistIndex: number | null; // Currently playing playlist (null if none)
  currentEntryIndex: number | null; // Currently playing entry (null if none)
  loopsRemaining: number | null; // Loops left on current entry (-1 if infinite)
  currentLoopIteration: number | null; // Current loop number (1-indexed)
  isPlaylistActive: boolean; // Playlist engine active (playing or paused)
  isPaused: boolean; // Playlist paused (vs actively playing)
  advanceAfterLoop: boolean; // Flag: will advance after current loop completes
}

// =============================================================================
// Peaks Response (from item/getPeaks command)
// =============================================================================

export interface PeaksResponsePayload {
  itemGUID: string;
  takeGUID: string;
  length: number; // Item length in seconds
  startOffset: number; // Take start offset (D_STARTOFFS)
  playrate: number; // Take playrate (D_PLAYRATE)
  channels: 1 | 2; // Mono or stereo
  peaks: StereoPeak[] | MonoPeak[];
}

// Stereo peak format: {l: [min, max], r: [min, max]}
export interface StereoPeak {
  l: [number, number];
  r: [number, number];
}

// Mono peak format: [min, max]
export type MonoPeak = [number, number];

// =============================================================================
// Connection State
// =============================================================================

export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error';

export interface WebSocketConnectionStatus {
  state: ConnectionState;
  errorCount: number;
  lastError: string | null;
  extensionVersion: string | null;
}

// =============================================================================
// Command Helpers
// =============================================================================

/** Generate a UUID - fallback for non-secure contexts (HTTP on iOS Safari) */
function generateUUID(): string {
  // crypto.randomUUID() requires HTTPS on Safari/iOS
  // Fall back to manual generation for HTTP contexts
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    try {
      return crypto.randomUUID();
    } catch {
      // Falls through to manual generation
    }
  }
  // Manual UUID v4 generation using crypto.getRandomValues (works on HTTP)
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 1
  const hex = [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Create a command message */
export function createCommand(
  command: string,
  params?: Record<string, unknown>,
  id?: string
): CommandMessage {
  return {
    type: 'command',
    command,
    id: id ?? generateUUID(),
    ...params,
  };
}

/** Create hello handshake */
export function createHello(token?: string): HelloMessage {
  return {
    type: 'hello',
    clientVersion: '1.0.0',
    protocolVersion: 1,
    token,
  };
}

// =============================================================================
// Type Guards
// =============================================================================

export function isHelloResponse(msg: unknown): msg is HelloResponse {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    (msg as HelloResponse).type === 'hello' &&
    'extensionVersion' in msg
  );
}

export function isClockSyncResponse(msg: unknown): msg is ClockSyncResponse {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    (msg as ClockSyncResponse).type === 'clockSyncResponse'
  );
}

export function isEventMessage(msg: unknown): msg is EventMessage {
  return (
    typeof msg === 'object' && msg !== null && (msg as EventMessage).type === 'event'
  );
}

export function isResponseMessage(msg: unknown): msg is ResponseMessage {
  return (
    typeof msg === 'object' && msg !== null && (msg as ResponseMessage).type === 'response'
  );
}

export function isTransportEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TransportEventPayload } {
  return msg.event === 'transport';
}

export function isTransportTickEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TransportTickEventPayload } {
  return msg.event === 'tt';
}

export function isProjectEvent(
  msg: EventMessage
): msg is EventMessage & { payload: ProjectEventPayload } {
  return msg.event === 'project';
}

export function isTracksEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TracksEventPayload } {
  return msg.event === 'tracks';
}

export function isMarkersEvent(
  msg: EventMessage
): msg is EventMessage & { payload: MarkersEventPayload } {
  return msg.event === 'markers';
}

export function isRegionsEvent(
  msg: EventMessage
): msg is EventMessage & { payload: RegionsEventPayload } {
  return msg.event === 'regions';
}

export function isItemsEvent(
  msg: EventMessage
): msg is EventMessage & { payload: ItemsEventPayload } {
  return msg.event === 'items';
}

export function isActionToggleStateEvent(
  msg: EventMessage
): msg is EventMessage & { payload: ActionToggleStateEventPayload } {
  return msg.event === 'actionToggleState';
}

export function isTempoMapEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TempoMapEventPayload } {
  return msg.event === 'tempoMap';
}

export function isProjectNotesChangedEvent(
  msg: EventMessage
): msg is EventMessage & { payload: ProjectNotesChangedEventPayload } {
  return msg.event === 'projectNotesChanged';
}

export function isPlaylistEvent(
  msg: EventMessage
): msg is EventMessage & { payload: PlaylistEventPayload } {
  return msg.event === 'playlist';
}
