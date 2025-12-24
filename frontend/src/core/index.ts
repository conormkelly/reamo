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
