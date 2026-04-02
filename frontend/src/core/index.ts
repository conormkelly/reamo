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
  TracksEventPayload,
  SkeletonTrack,
  TrackSkeletonEventPayload,
  MeterData,
  MetersEventPayload,
  WSMarker,
  MarkersEventPayload,
  WSRegion,
  RegionsEventPayload,
  WSTake,
  WSItem,
  ItemsEventPayload,
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
  isTrackSkeletonEvent,
  isTracksEvent,
  isMetersEvent,
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

