/**
 * Tests for time selection handling in the store
 *
 * These tests verify how the store processes timeSelection from WebSocket
 * transport events and how it's exposed for UI consumption.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from './index';
import type { ServerMessage } from '../core/WebSocketTypes';

// Helper to create a transport event message
function createTransportEvent(overrides: {
  timeSelection?: { start: number; end: number };
  bpm?: number;
  position?: number;
}): ServerMessage {
  return {
    type: 'event',
    event: 'transport',
    payload: {
      playState: 0,
      position: overrides.position ?? 0,
      positionBeats: '1.1.00',
      cursorPosition: 0,
      bpm: overrides.bpm ?? 120,
      timeSignature: { numerator: 4, denominator: 4 },
      timeSelection: overrides.timeSelection ?? { start: 0, end: 0 },
      repeat: false,
      metronome: { enabled: false, volume: 0.25, volumeDb: -12 },
      projectLength: 300,
      barOffset: 0,
    },
  };
}

describe('Store timeSelection handling', () => {
  beforeEach(() => {
    // Reset store to initial state
    useReaperStore.setState({
      timeSelection: null,
      bpm: null,
    });
  });

  describe('handleWebSocketMessage - transport events', () => {
    it('stores time selection when start !== end', () => {
      const store = useReaperStore.getState();

      // Server sends time selection from 10s to 20s
      const message = createTransportEvent({
        timeSelection: { start: 10, end: 20 },
        bpm: 120,
      });

      store.handleWebSocketMessage(message);

      const state = useReaperStore.getState();
      expect(state.timeSelection).not.toBeNull();
      // Seconds are stored directly
      expect(state.timeSelection?.startSeconds).toBeCloseTo(10, 1);
      expect(state.timeSelection?.endSeconds).toBeCloseTo(20, 1);
    });

    it('stores null when start === end (no selection)', () => {
      const store = useReaperStore.getState();

      const message = createTransportEvent({
        timeSelection: { start: 5, end: 5 },
        bpm: 120,
      });

      store.handleWebSocketMessage(message);

      expect(useReaperStore.getState().timeSelection).toBeNull();
    });

    it('stores null when both start and end are 0', () => {
      const store = useReaperStore.getState();

      const message = createTransportEvent({
        timeSelection: { start: 0, end: 0 },
        bpm: 120,
      });

      store.handleWebSocketMessage(message);

      expect(useReaperStore.getState().timeSelection).toBeNull();
    });

    it('handles selection starting at time 0', () => {
      const store = useReaperStore.getState();

      // Selection from project start (0s) to 8s
      const message = createTransportEvent({
        timeSelection: { start: 0, end: 8 },
        bpm: 120,
      });

      store.handleWebSocketMessage(message);

      const state = useReaperStore.getState();
      expect(state.timeSelection).not.toBeNull();
      // Seconds are stored directly
      expect(state.timeSelection?.startSeconds).toBeCloseTo(0, 1);
      expect(state.timeSelection?.endSeconds).toBeCloseTo(8, 1);
    });

    it('stores seconds directly regardless of BPM', () => {
      const store = useReaperStore.getState();

      // Server sends 10-20s (BPM doesn't affect storage)
      const message = createTransportEvent({
        timeSelection: { start: 10, end: 20 },
        bpm: 90,
      });

      store.handleWebSocketMessage(message);

      const state = useReaperStore.getState();
      // Seconds are stored directly, BPM is irrelevant
      expect(state.timeSelection?.startSeconds).toBeCloseTo(10, 1);
      expect(state.timeSelection?.endSeconds).toBeCloseTo(20, 1);
    });

    it('passes BPM through unchanged for non-quarter-note denominators', () => {
      const store = useReaperStore.getState();

      // REAPER's TimeMap_GetTimeSigAtTime always returns quarter-note BPM
      // In 6/8 at 90 BPM, REAPER sends 90 (not 180 eighth-notes)
      const message: ServerMessage = {
        type: 'event',
        event: 'transport',
        payload: {
          playState: 0,
          position: 0,
          positionBeats: '1.1.00',
          cursorPosition: 0,
          bpm: 90, // Quarter-note BPM (REAPER always sends quarter-note BPM)
          timeSignature: { numerator: 6, denominator: 8 },
          timeSelection: { start: 4, end: 8 },
          repeat: false,
          metronome: { enabled: false, volume: 0.25, volumeDb: -12 },
          projectLength: 300,
          barOffset: 0,
        },
      };

      store.handleWebSocketMessage(message);

      const state = useReaperStore.getState();
      // BPM passes through unchanged (REAPER's TimeMap_GetTimeSigAtTime returns quarter-note BPM)
      expect(state.bpm).toBeCloseTo(90, 0);
      // Time selection stored in seconds directly
      expect(state.timeSelection?.startSeconds).toBeCloseTo(4, 1);
      expect(state.timeSelection?.endSeconds).toBeCloseTo(8, 1);
    });

    it('updates time selection on subsequent messages', () => {
      const store = useReaperStore.getState();

      // First message: selection 10-20s
      store.handleWebSocketMessage(
        createTransportEvent({
          timeSelection: { start: 10, end: 20 },
          bpm: 120,
        })
      );

      expect(useReaperStore.getState().timeSelection?.startSeconds).toBeCloseTo(10, 1);

      // Second message: selection changes to 30-40s
      store.handleWebSocketMessage(
        createTransportEvent({
          timeSelection: { start: 30, end: 40 },
          bpm: 120,
        })
      );

      const state = useReaperStore.getState();
      // Seconds stored directly
      expect(state.timeSelection?.startSeconds).toBeCloseTo(30, 1);
      expect(state.timeSelection?.endSeconds).toBeCloseTo(40, 1);
    });

    it('clears time selection when server sends equal start/end', () => {
      const store = useReaperStore.getState();

      // First: set a selection
      store.handleWebSocketMessage(
        createTransportEvent({
          timeSelection: { start: 10, end: 20 },
          bpm: 120,
        })
      );

      expect(useReaperStore.getState().timeSelection).not.toBeNull();

      // Then: clear it (start === end)
      store.handleWebSocketMessage(
        createTransportEvent({
          timeSelection: { start: 0, end: 0 },
          bpm: 120,
        })
      );

      expect(useReaperStore.getState().timeSelection).toBeNull();
    });
  });

  describe('setTimeSelection action', () => {
    it('sets time selection directly', () => {
      const store = useReaperStore.getState();

      store.setTimeSelection({ startSeconds: 4, endSeconds: 8 });

      const state = useReaperStore.getState();
      expect(state.timeSelection?.startSeconds).toBe(4);
      expect(state.timeSelection?.endSeconds).toBe(8);
    });

    it('clears time selection when set to null', () => {
      const store = useReaperStore.getState();

      // First set a selection
      store.setTimeSelection({ startSeconds: 4, endSeconds: 8 });
      expect(useReaperStore.getState().timeSelection).not.toBeNull();

      // Then clear it
      store.setTimeSelection(null);
      expect(useReaperStore.getState().timeSelection).toBeNull();
    });
  });

  describe('edge cases', () => {
    it('handles very small time selections', () => {
      const store = useReaperStore.getState();

      // Selection of 0.001 seconds
      const message = createTransportEvent({
        timeSelection: { start: 10, end: 10.001 },
        bpm: 120,
      });

      store.handleWebSocketMessage(message);

      // Should still store it (filtering happens in UI)
      const state = useReaperStore.getState();
      expect(state.timeSelection).not.toBeNull();
    });

    it('handles very large time values', () => {
      const store = useReaperStore.getState();

      // 1 hour selection
      const message = createTransportEvent({
        timeSelection: { start: 0, end: 3600 },
        bpm: 120,
      });

      store.handleWebSocketMessage(message);

      const state = useReaperStore.getState();
      // Seconds stored directly
      expect(state.timeSelection?.startSeconds).toBeCloseTo(0, 1);
      expect(state.timeSelection?.endSeconds).toBeCloseTo(3600, 1);
    });

    it('handles fractional seconds with high precision', () => {
      const store = useReaperStore.getState();

      // REAPER sends high-precision floats
      const message = createTransportEvent({
        timeSelection: { start: 13.333333333333314, end: 26.666666666666628 },
        bpm: 120,
      });

      store.handleWebSocketMessage(message);

      const state = useReaperStore.getState();
      // Seconds stored directly with full precision
      expect(state.timeSelection?.startSeconds).toBeCloseTo(13.333, 2);
      expect(state.timeSelection?.endSeconds).toBeCloseTo(26.667, 2);
    });
  });
});
