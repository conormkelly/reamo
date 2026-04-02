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

export type EventType = 'transport' | 'tt' | 'project' | 'trackSkeleton' | 'tracks' | 'meters' | 'markers' | 'regions' | 'items' | 'fx_state' | 'sends_state' | 'routing_state' | 'reload' | 'actionToggleState' | 'tempoMap' | 'projectNotesChanged' | 'playlist' | 'peaks' | 'trackFxChain' | 'trackFxParams' | 'trackFxParamsError' | 'tuner' | 'tunerError';

export type EventPayload =
  | TransportEventPayload
  | TransportTickEventPayload
  | ProjectEventPayload
  | TrackSkeletonEventPayload
  | TracksEventPayload
  | MetersEventPayload
  | MarkersEventPayload
  | RegionsEventPayload
  | ItemsEventPayload
  | FxStateEventPayload
  | SendsStateEventPayload
  | RoutingStateEventPayload
  | ActionToggleStateEventPayload
  | TempoMapEventPayload
  | ProjectNotesChangedEventPayload
  | PlaylistEventPayload
  | PeaksEventPayload
  | FxChainEventPayload
  | FxParamsEventPayload
  | FxParamsErrorEventPayload
  | TunerEventPayload
  | TunerErrorEventPayload;

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
  projectName: string; // Project filename (e.g., "My Song.rpp")
  // Project-level settings (moved from transport for efficiency)
  repeat: boolean;
  metronome: {
    enabled: boolean;
    volume: number; // linear 0-4
    volumeDb: number; // dB
  };
  countIn: {
    playback: boolean;
    recording: boolean;
  };
  preRoll: {
    playback: boolean;
    recording: boolean;
  };
  master: {
    stereoEnabled: boolean; // true = stereo, false = mono (L+R summed)
  };
  projectLength: number; // seconds
  barOffset: number; // bar offset (e.g., -4 means time 0 = bar 1, display starts at bar -4)
  isDirty: boolean; // Project has unsaved changes
  memoryWarning: boolean; // Arena utilization warning (any tier > 80% peak usage)
}

// =============================================================================
// Track Skeleton Event (lightweight list for filtering/navigation)
// =============================================================================

/** Lightweight track info for skeleton event with filter fields for built-in banks */
export interface SkeletonTrack {
  n: string; // name
  g: string; // guid ("master" for master track)
  // Filter fields for built-in banks (enable filtering without full track subscription)
  m: boolean; // mute
  sl: number | null; // solo (null=off, 0=solo, 2=solo-in-place)
  sel: boolean; // selected
  r: boolean; // rec-armed
  fd: number; // folder_depth (1=folder parent, 0=normal, -N=closes N folders)
  sc: number; // send_count
  hc: number; // hw_output_count
  cl: boolean; // clipped (sticky flag, L or R channel exceeded 0dB)
  ic: number; // item_count (number of media items on track)
  fm: number; // free_mode (0=normal, 1=free positioning, 2=fixed lanes)
  c: number; // color (0x01rrggbb, 0 = theme default)
}

/** Track skeleton broadcast (1Hz, on structure change) */
export interface TrackSkeletonEventPayload {
  tracks: SkeletonTrack[];
}

// =============================================================================
// Tracks Event (subscribed tracks only)
// =============================================================================

export interface WSTrack {
  idx: number;
  g: string; // Track GUID ("master" for master track) — use for write commands (backend sends "g" for compactness)
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
  // Sparse counts (full data fetched on-demand via track/getFx, track/getSends, track/getHwOutputs)
  fxCount: number;
  sendCount: number;
  receiveCount: number;
  hwOutCount: number;
  // Input selection (only present when recArm=true)
  recInput?: number; // Raw I_RECINPUT value - decode with utils/input.ts
}

/** Tracks event payload (only contains subscribed tracks) */
export interface TracksEventPayload {
  total: number; // User track count (excludes master, for virtual scroll sizing)
  tracks: WSTrack[];
  // Note: meters removed - now sent separately via 'meters' event
}

// =============================================================================
// Meters Event (GUID-keyed map, 30Hz for subscribed tracks)
// =============================================================================

/** Individual meter data for a track */
export interface MeterData {
  i: number; // track index
  l: number; // left peak (0-1+, 1.0 = 0dB)
  r: number; // right peak
  c: boolean; // clipped (sticky until cleared)
}

/** Meters event payload (GUID-keyed map for O(1) lookup) */
export interface MetersEventPayload {
  m: Record<string, MeterData>; // GUID → meter data
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
  // Sparse fields (full data fetched on-demand via item/getNotes, item/getTakes)
  hasNotes: boolean;
  takeCount: number;
  activeTakeName: string; // Display name for active take
  activeTakeGuid: string; // For peaks cache invalidation
  activeTakeIsMidi: boolean; // Skip peaks for MIDI items
  activeTakeColor: number | null; // Custom color of active take (null = no custom color)
}

export interface ItemsEventPayload {
  items: WSItem[];
  // Note: timeSelection is in TransportEventPayload, not here
}

// =============================================================================
// FX State Event (5Hz broadcast - flat FX list across all tracks)
// =============================================================================

export interface WSFxSlot {
  trackIdx: number; // Parent track (unified: 0 = master, 1+ = user tracks)
  fxIndex: number; // Position in track's FX chain
  name: string;
  presetName: string;
  presetIndex: number; // -1 if no preset loaded
  presetCount: number;
  modified: boolean; // Preset has been modified
  enabled: boolean;
}

export interface FxStateEventPayload {
  fx: WSFxSlot[];
}

// =============================================================================
// Sends State Event (5Hz broadcast - flat sends list across all tracks)
// =============================================================================

export interface WSSendSlot {
  srcTrackIdx: number; // Source track (unified: 0 = master, 1+ = user tracks)
  destTrackIdx: number; // Destination track
  sendIndex: number; // Position in source track's send list
  volume: number; // Linear: 1.0 = 0dB
  pan: number; // -1 to 1
  muted: boolean;
  mode: number; // 0=post-fader, 1=pre-fx, 3=pre-fader
}

export interface SendsStateEventPayload {
  sends: WSSendSlot[];
}

// =============================================================================
// Routing State Event (30Hz per-client subscription)
// =============================================================================

/** Send slot in routing subscription (includes pan, unlike WSSendSlot) */
export interface WSRoutingSend {
  sendIndex: number;
  destName: string;
  volume: number;  // Linear: 1.0 = 0dB
  pan: number;     // -1 to 1
  muted: boolean;
  mode: number;    // 0=post-fader, 1=pre-fx, 3=post-fx
}

/** Receive slot in routing subscription */
export interface WSRoutingReceive {
  receiveIndex: number;
  srcName: string;
  volume: number;  // Linear: 1.0 = 0dB
  pan: number;     // -1 to 1
  muted: boolean;
  mode: number;    // 0=post-fader, 1=pre-fx, 3=post-fx
}

/** Hardware output slot in routing subscription */
export interface WSRoutingHwOutput {
  hwIdx: number;
  destChannel: number;  // Encoded: lower 10 bits = channel, upper bits = num channels
  volume: number;       // Linear: 1.0 = 0dB
  pan: number;          // -1 to 1
  muted: boolean;
  mode: number;         // 0=post-fader, 1=pre-FX, 3=post-FX
}

/** Routing state event payload (per-client, pushed by backend at 30Hz) */
export interface RoutingStateEventPayload {
  trackGuid: string;
  sends: WSRoutingSend[];
  receives: WSRoutingReceive[];
  hwOutputs: WSRoutingHwOutput[];
}

// =============================================================================
// FX Chain Subscription Event (per-client, pushed by backend at 30Hz)
// =============================================================================

/** Individual FX slot in chain subscription (richer than WSFxSlot from broadcast) */
export interface WSFxChainSlot {
  fxGuid: string;     // Stable identifier (survives FX reorder)
  fxIndex: number;    // Position in track's FX chain
  name: string;
  presetName: string;
  presetIndex: number; // -1 if no preset loaded
  presetCount: number;
  modified: boolean;   // Preset has been modified
  enabled: boolean;
}

/** FX chain event payload (per-client, pushed by backend at 30Hz) */
export interface FxChainEventPayload {
  trackGuid: string;
  fx: WSFxChainSlot[];
}

// =============================================================================
// FX Parameter Subscription Events (per-client, pushed by backend at 30Hz)
// =============================================================================

/** FX parameters event payload (subscribed params only) */
export interface FxParamsEventPayload {
  trackGuid: string;
  fxGuid: string;
  paramCount: number;  // Total params (for skeleton invalidation)
  nameHash: number;    // Hash of param names (for skeleton invalidation)
  values: Record<string, [number, string]>; // "0": [normalized, formatted]
}

/** FX params error event (FX deleted while subscribed) */
export interface FxParamsErrorEventPayload {
  error: string; // "FX_NOT_FOUND"
}

// =============================================================================
// Tuner Event (per-client, pushed by backend at 30Hz)
// =============================================================================

/** Tuner event payload with pitch detection data */
export interface TunerEventPayload {
  trackGuid: string;
  freq: number;      // Detected frequency in Hz (0 = no signal)
  note: number;      // MIDI note number (69 = A4)
  noteName: string;  // "C", "C#", "D", etc.
  octave: number;    // Octave number (4 for A4)
  cents: number;     // Deviation from note (-50 to +50)
  conf: number;      // Detection confidence (0-1)
  inTune: boolean;   // True when |cents| < 2
  // Settings (for multi-client sync)
  referenceHz: number;  // A4 reference frequency (400-480)
  thresholdDb: number;  // Silence threshold in dB (-90 to -30)
}

/** Tuner error event (track/tuner deleted while subscribed) */
export interface TunerErrorEventPayload {
  error: string;     // "TUNER_NOT_FOUND" | "GENERATION_FAILED"
}

// =============================================================================
// Hardware Output Types (on-demand via track/getHwOutputs)
// =============================================================================

export interface WSHardwareOutputSlot {
  hwIdx: number;         // 0-based hardware output index
  destChannel: number;   // Output channel (encoded: lower 10 bits = channel, upper bits = num channels)
  volume: number;        // Linear: 1.0 = 0dB
  pan: number;           // -1.0 to 1.0
  muted: boolean;
  mode: number;          // 0=post-fader, 1=pre-FX, 3=post-FX
}

// =============================================================================
// Action Toggle State Event
// =============================================================================

/** Single toggle state change entry */
export interface ToggleStateChange {
  s: number; // sectionId
  c: number; // commandId
  v: number; // value (-1, 0, or 1)
}

/** Toggle state changes broadcast (sparse delta) */
export interface ActionToggleStateEventPayload {
  changes: ToggleStateChange[]; // Array of section-aware toggle state changes
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
// Peaks Subscription Event (per-client, pushed by backend) - TILE-BASED LOD
// =============================================================================

/** LOD level type (0=coarsest overview, 7=finest detail)
 * See docs/architecture/LOD_LEVELS.md for full configuration.
 */
export type LODLevel = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7;

/** LOD configuration constants matching backend peaks_tile.zig
 * 8 levels with 4x ratio between adjacent levels.
 * Optimized for 1s-4hr viewport range, targeting 2-4 peaks/pixel at 400px width.
 */
export const LOD_CONFIGS = {
  0: { duration: 4096, peakrate: 0.0625, peaksPerTile: 256 }, // > 5hr viewport
  1: { duration: 1024, peakrate: 0.25, peaksPerTile: 256 },   // 80min - 5hr
  2: { duration: 256, peakrate: 1, peaksPerTile: 256 },       // 20min - 80min
  3: { duration: 64, peakrate: 4, peaksPerTile: 256 },        // 5min - 20min
  4: { duration: 16, peakrate: 16, peaksPerTile: 256 },       // 75s - 5min
  5: { duration: 4, peakrate: 64, peaksPerTile: 256 },        // 20s - 75s
  6: { duration: 1, peakrate: 256, peaksPerTile: 256 },       // 5s - 20s
  7: { duration: 0.5, peakrate: 1024, peaksPerTile: 512 },    // < 5s (finest)
} as const;

/** Single tile of peaks data from backend */
export interface PeaksTile {
  takeGuid: string;          // Take GUID for cache key
  epoch: number;             // Cache invalidation signal (changes when source audio edited)
  lod: LODLevel;             // LOD level (0-7, see LOD_CONFIGS)
  tileIndex: number;         // Position within item (0-indexed)
  itemPosition: number;      // Item start position in project time (seconds)
  startTime: number;         // Tile start time relative to item start (seconds)
  endTime: number;           // Tile end time relative to item start (seconds)
  channels: 1 | 2;
  peaks: StereoPeak[] | MonoPeak[];
}

/** Cache key for tile lookup */
export interface TileCacheKey {
  takeGuid: string;
  epoch: number;
  lod: LODLevel;
  tileIndex: number;
}

/** Peaks event payload - tile-based format
 *
 * Example:
 * {
 *   "tiles": [
 *     {
 *       "takeGuid": "{XXXX...}",
 *       "epoch": 2355337060,
 *       "lod": 1,
 *       "tileIndex": 5,
 *       "itemPosition": 100.0,
 *       "startTime": 40.0,
 *       "endTime": 48.0,
 *       "channels": 2,
 *       "peaks": [{"l": [-0.5, 0.6], "r": [-0.4, 0.5]}, ...]
 *     }
 *   ]
 * }
 */
export interface PeaksEventPayload {
  tiles: PeaksTile[];
}

// -----------------------------------------------------------------------------
// DEPRECATED - Old item-based format (kept for backward compat with item/getPeaks)
// -----------------------------------------------------------------------------

/** Calculate LOD level from viewport (must match backend peaks_tile.zig logic)
 * Uses viewport duration thresholds - see docs/architecture/LOD_LEVELS.md
 */
export function calculateLODFromViewport(
  viewportStart: number,
  viewportEnd: number,
  _widthPx: number // Unused - thresholds based on duration, not pixels
): LODLevel {
  const duration = viewportEnd - viewportStart;
  if (duration <= 0) return 5; // Default to LOD 5 (normal editing)

  if (duration < 5) return 7;      // < 5s: finest detail
  if (duration < 20) return 6;     // 5-20s: precision editing
  if (duration < 75) return 5;     // 20-75s: normal editing
  if (duration < 300) return 4;    // 75s-5min: wide view
  if (duration < 1200) return 3;   // 5-20min: overview
  if (duration < 4800) return 2;   // 20-80min: large project
  if (duration < 19200) return 1;  // 80min-5hr: multi-hour
  return 0;                         // > 5hr: extreme overview
}

/** Create a tile cache key string for Map storage */
export function makeTileCacheKeyString(key: TileCacheKey): string {
  return `${key.takeGuid}:${key.epoch}:${key.lod}:${key.tileIndex}`;
}

/** Get tile indices that cover a time range at a given LOD */
export function getTileRange(
  startTime: number,
  endTime: number,
  lod: LODLevel
): { start: number; end: number } {
  const config = LOD_CONFIGS[lod];
  return {
    start: Math.max(0, Math.floor(startTime / config.duration)),
    end: Math.ceil(endTime / config.duration),
  };
}

// -----------------------------------------------------------------------------
// DEPRECATED - Old item-based format (kept for backward compat with item/getPeaks)
// -----------------------------------------------------------------------------

/** @deprecated Use PeaksTile instead - individual item's peaks from old format */
export interface WSItemPeaks {
  itemGuid: string;
  trackIdx: number;
  itemIdx: number;
  position: number; // seconds
  length: number; // seconds
  channels: 1 | 2;
  peaks: StereoPeak[] | MonoPeak[];
}

/** @deprecated Use PeaksEventPayload with tiles instead */
export interface TrackPeaksData {
  guid: string;
  items: WSItemPeaks[];
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

export function isTrackSkeletonEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TrackSkeletonEventPayload } {
  return msg.event === 'trackSkeleton';
}

export function isTracksEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TracksEventPayload } {
  return msg.event === 'tracks';
}

export function isMetersEvent(
  msg: EventMessage
): msg is EventMessage & { payload: MetersEventPayload } {
  return msg.event === 'meters';
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

export function isFxStateEvent(
  msg: EventMessage
): msg is EventMessage & { payload: FxStateEventPayload } {
  return msg.event === 'fx_state';
}

export function isSendsStateEvent(
  msg: EventMessage
): msg is EventMessage & { payload: SendsStateEventPayload } {
  return msg.event === 'sends_state';
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

export function isPeaksEvent(
  msg: EventMessage
): msg is EventMessage & { payload: PeaksEventPayload } {
  return msg.event === 'peaks';
}

export function isRoutingStateEvent(
  msg: EventMessage
): msg is EventMessage & { payload: RoutingStateEventPayload } {
  return msg.event === 'routing_state';
}

export function isFxChainEvent(
  msg: EventMessage
): msg is EventMessage & { payload: FxChainEventPayload } {
  return msg.event === 'trackFxChain';
}

export function isFxParamsEvent(
  msg: EventMessage
): msg is EventMessage & { payload: FxParamsEventPayload } {
  return msg.event === 'trackFxParams';
}

export function isFxParamsErrorEvent(
  msg: EventMessage
): msg is EventMessage & { payload: FxParamsErrorEventPayload } {
  return msg.event === 'trackFxParamsError';
}

export function isTunerEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TunerEventPayload } {
  return msg.event === 'tuner';
}

export function isTunerErrorEvent(
  msg: EventMessage
): msg is EventMessage & { payload: TunerErrorEventPayload } {
  return msg.event === 'tunerError';
}
