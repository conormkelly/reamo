// Core types
export * from './types';

// WebSocket types (selective to avoid conflicts with types.ts)
export type {
  MessageType,
  HelloMessage,
  HelloResponse,
  CommandMessage,
  ResponseMessage,
  EventMessage,
  EventType,
  EventPayload,
  ServerMessage,
  TransportEventPayload,
  WSTrack,
  WSMeter,
  TracksEventPayload,
  WSMarker,
  MarkersEventPayload,
  WSRegion,
  RegionsEventPayload,
  WSTake,
  WSItem,
  ItemsEventPayload,
  PeaksResponsePayload,
  StereoPeak,
  MonoPeak,
  ConnectionState,
  WebSocketConnectionStatus,
} from './WebSocketTypes';

export {
  createCommand,
  createHello,
  isHelloResponse,
  isEventMessage,
  isResponseMessage,
  isTransportEvent,
  isTracksEvent,
  isMarkersEvent,
  isRegionsEvent,
  isItemsEvent,
} from './WebSocketTypes';

// WebSocket connection
export { WebSocketConnection, type WebSocketConnectionOptions } from './WebSocketConnection';

// WebSocket commands
export * as commands from './WebSocketCommands';

// Transport animation engine (client-side interpolation)
export {
  TransportAnimationEngine,
  transportEngine,
  type TransportAnimationState,
  type TransportSubscriber,
} from './TransportAnimationEngine';

// Peaks cache (for waveform data)
export { peaksCache, buildPeaksCacheKey, type PeaksCacheKey } from './PeaksCache';
