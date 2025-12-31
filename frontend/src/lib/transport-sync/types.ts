/**
 * Transport Sync Types
 *
 * Shared types for the transport synchronization system.
 */

/** Sample from a clock sync exchange */
export interface SyncSample {
  rtt: number;
  offset: number;
  time: number;
}

/** Drift measurement over time */
export interface DriftRecord {
  time: number;
  driftPpm: number;
}

/** Result of a clock sync operation */
export interface SyncResult {
  offset: number;
  rtt: number;
  accuracy: number;
}

/** Clock sync metrics for debugging/display */
export interface ClockSyncMetrics {
  offset: number;
  lastRtt: number;
  estimatedDrift: number;
}

/** Clock sync response from server */
export interface ClockSyncResponse {
  t0: number;
  t1: number;
  t2: number;
}

/** Transport event payload with sync fields */
export interface TransportSyncPayload {
  t: number;  // Server timestamp (ms)
  b: number;  // Raw beat position
  bpm: number;
  playState: number;
  // Other existing fields...
}

/** Time signature */
export interface TimeSignature {
  numerator: number;
  denominator: number;
}

/** Time provider interface for dependency injection (testability) */
export interface TimeProvider {
  now(): number;
}

/** Default time provider using performance.now() */
export const defaultTimeProvider: TimeProvider = {
  now: () => performance.now(),
};
