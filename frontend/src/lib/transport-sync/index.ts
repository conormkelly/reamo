/**
 * Transport Sync Library
 *
 * Production-grade visual latency compensation for REAPER transport display.
 * Synchronizes beat indicators with audio playback over WiFi to ±15ms accuracy.
 */

export { ClockSync, type SendSyncRequest } from './ClockSync';
export { BeatPredictor, type ServerState, type ClockSyncInterface } from './BeatPredictor';
export * from './types';
