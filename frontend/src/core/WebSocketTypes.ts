/**
 * WebSocket API Types
 * Based on extension/API.md protocol specification
 */

// =============================================================================
// Protocol Messages
// =============================================================================

/** Base message types */
export type MessageType = 'hello' | 'command' | 'response' | 'event';

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
}

/** Command message (client → server) */
export interface CommandMessage {
  type: 'command';
  command: string;
  id?: string;
  [key: string]: unknown; // Additional parameters
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
  payload: EventPayload;
}

export type EventType = 'transport' | 'tracks' | 'markers' | 'regions' | 'items';

export type EventPayload =
  | TransportEventPayload
  | TracksEventPayload
  | MarkersEventPayload
  | RegionsEventPayload
  | ItemsEventPayload;

/** Any message from server */
export type ServerMessage = HelloResponse | ResponseMessage | EventMessage;

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
  repeat: boolean;
  metronome: {
    enabled: boolean;
    volume: number; // linear 0-4
    volumeDb: number; // dB
  };
  projectLength: number; // seconds
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
  isActive: boolean;
}

export interface WSItem {
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
  timeSelection: {
    start: number;
    end: number;
  };
  items: WSItem[];
}

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
