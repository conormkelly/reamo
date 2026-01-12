/**
 * Reactper - REAPER Web Control Library
 * A React/TypeScript library for building REAPER control surfaces
 */

// Core exports (explicit to avoid conflicts)
export {
  // Types
  type PlayState,
  type TransportState,
  type BeatPosition,
  type Track,
  type Send,
  type Marker,
  type Region,
  type CommandState,
  type ExtState,
  type ParsedResponse,
  type ConnectionStatus as ConnectionStatusType,
  // Type helpers
  PlayStateLabel,
  TrackFlags,
  ActionCommands,
  isMuted,
  isSoloed,
  isRecordArmed,
  isSelected,
  isFxDisabled,
  getRecordMonitorState,
  isSendMuted,
  // WebSocket connection
  WebSocketConnection,
  type WebSocketConnectionOptions,
  // Commands (WebSocket-based)
  commands,
} from './core';

// Store exports
export { useReaperStore, type ReaperStore } from './store';

// Hook exports
export * from './hooks';

// Component exports
export * from './components';

// Utility exports
export * from './utils';
