/**
 * Transport Sync Library
 *
 * Production-grade visual latency compensation for REAPER transport display.
 * Synchronizes beat indicators with audio playback over WiFi to ±15ms accuracy.
 */

// Core sync classes
export { ClockSync, type SendSyncRequest } from './ClockSync';
export { BeatPredictor, type ServerState, type ClockSyncInterface, type TempoMarker } from './BeatPredictor';

// Jitter compensation
export { JitterMeasurement } from './JitterMeasurement';
export { AdaptiveBuffer, type NetworkQuality } from './AdaptiveBuffer';

// Network state machine
export { NetworkState, type NetworkStatus, type NetworkStateCallbacks } from './NetworkState';

// Shared types
export * from './types';
