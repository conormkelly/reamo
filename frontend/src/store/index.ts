/**
 * Main Zustand store
 * Combines all slices and provides response handling
 */

import { create } from 'zustand';
import { createConnectionSlice, type ConnectionSlice } from './slices/connectionSlice';
import { createTransportSlice, type TransportSlice } from './slices/transportSlice';
import { createProjectSlice, type ProjectSlice } from './slices/projectSlice';
import { createTracksSlice, type TracksSlice } from './slices/tracksSlice';
import { createRegionsSlice, type RegionsSlice } from './slices/regionsSlice';
import { createMarkersSlice, type MarkersSlice } from './slices/markersSlice';
import { createRegionEditSlice, type RegionEditSlice } from './slices/regionEditSlice';
import { createItemsSlice, type ItemsSlice } from './slices/itemsSlice';
import type { ParsedResponse, Region, Marker, CommandState } from '../core/types';
import { ActionCommands, SWSCommands } from '../core/types';
import type {
  ServerMessage,
  TransportEventPayload,
  ProjectEventPayload,
  TracksEventPayload,
  MarkersEventPayload,
  RegionsEventPayload,
  ItemsEventPayload,
} from '../core/WebSocketTypes';
import {
  isEventMessage,
  isTransportEvent,
  isProjectEvent,
  isTracksEvent,
  isMarkersEvent,
  isRegionsEvent,
  isItemsEvent,
} from '../core/WebSocketTypes';
import { transportEngine } from '../core/TransportAnimationEngine';

// Combined store type
export type ReaperStore = ConnectionSlice & TransportSlice & ProjectSlice & TracksSlice & RegionsSlice & MarkersSlice & RegionEditSlice & ItemsSlice & {
  // Response handler action (legacy HTTP)
  handleResponses: (responses: ParsedResponse[]) => void;
  // WebSocket message handler
  handleWebSocketMessage: (message: ServerMessage) => void;
  // Test mode - when enabled, skips WebSocket message processing to allow fixtures to persist
  _testMode: boolean;
  _setTestMode: (enabled: boolean) => void;
};

// Create the combined store
export const useReaperStore = create<ReaperStore>()((set, get, store) => ({
  // Test mode - prevents WebSocket from overwriting fixtures in E2E tests
  _testMode: false,
  _setTestMode: (enabled: boolean) => set({ _testMode: enabled }),

  // Spread all slices
  ...createConnectionSlice(set, get, store),
  ...createTransportSlice(set, get, store),
  ...createProjectSlice(set, get, store),
  ...createTracksSlice(set, get, store),
  ...createRegionsSlice(set, get, store),
  ...createMarkersSlice(set, get, store),
  ...createRegionEditSlice(set, get, store),
  ...createItemsSlice(set, get, store),

  // Handle incoming responses from REAPER
  handleResponses: (responses: ParsedResponse[]) => {
    // Collect regions and markers from list responses
    const collectedRegions: Region[] = [];
    const collectedMarkers: Marker[] = [];
    let inRegionList = false;
    let inMarkerList = false;

    for (const response of responses) {
      switch (response.type) {
        case 'TRANSPORT':
          get().updateTransport(response.data);
          break;

        case 'NTRACK':
          get().setTrackCount(response.count);
          break;

        case 'TRACK':
          get().updateTrack(response.data);
          break;

        case 'BEATPOS':
          get().updateBeatPosition(response.data);
          break;

        case 'GET/REPEAT':
          get().setRepeat(response.value);
          break;

        case 'REGION_LIST':
          inRegionList = true;
          break;

        case 'REGION':
          if (inRegionList) {
            collectedRegions.push(response.data);
          }
          break;

        case 'REGION_LIST_END':
          if (inRegionList) {
            get().setRegions(collectedRegions);
            inRegionList = false;
          }
          break;

        case 'MARKER_LIST':
          inMarkerList = true;
          break;

        case 'MARKER':
          if (inMarkerList) {
            collectedMarkers.push(response.data);
          }
          break;

        case 'MARKER_LIST_END':
          if (inMarkerList) {
            get().setMarkers(collectedMarkers);
            inMarkerList = false;
          }
          break;

        case 'CMDSTATE': {
          const cmdState = response.data as CommandState;
          if (cmdState.commandId === ActionCommands.TOGGLE_METRONOME) {
            get().setMetronome(cmdState.state === 1);
          } else if (cmdState.commandId === ActionCommands.AUTO_PUNCH) {
            get().setAutoPunch(cmdState.state === 1);
          } else if (cmdState.commandId === SWSCommands.COUNT_IN_RECORD) {
            get().setCountInRecord(cmdState.state === 1);
          } else if (cmdState.commandId === SWSCommands.COUNT_IN_PLAYBACK) {
            get().setCountInPlayback(cmdState.state === 1);
          }
          break;
        }

        default:
          break;
      }
    }
  },

  // Handle WebSocket messages
  handleWebSocketMessage: (message: ServerMessage) => {
    // Skip processing in test mode to preserve fixtures
    if (get()._testMode) return;
    if (!isEventMessage(message)) return;

    if (isTransportEvent(message)) {
      const p = message.payload as TransportEventPayload;
      // REAPER's BPM is in denominator beats per minute (e.g., eighths for 6/8)
      // Normalize to quarter-note BPM for consistent display
      // For 4/4: bpm * (4/4) = no change
      // For 6/8: bpm * (4/8) = bpm * 0.5 (180 eighth-note BPM → 90 quarter-note BPM)
      const normalizedBpm = p.bpm * (4 / p.timeSignature.denominator);

      // Feed transport animation engine for client-side interpolation
      // barOffset comes from project event now, use current state
      transportEngine.onServerUpdate({
        position: p.position,
        positionBeats: p.positionBeats,
        bpm: normalizedBpm,
        playState: p.playState,
        timeSignatureNumerator: p.timeSignature.numerator,
        timeSignatureDenominator: p.timeSignature.denominator,
        barOffset: get().barOffset,
      });

      set({
        playState: p.playState,
        positionSeconds: p.position,
        positionBeats: p.positionBeats,
        bpm: normalizedBpm,
        timeSignatureNumerator: p.timeSignature.numerator,
        timeSignatureDenominator: p.timeSignature.denominator,
        timeSelection: p.timeSelection.start !== p.timeSelection.end
          ? {
              startSeconds: p.timeSelection.start,
              endSeconds: p.timeSelection.end,
            }
          : null,
      });
    } else if (isProjectEvent(message)) {
      const p = message.payload as ProjectEventPayload;
      get().setReaperUndoState(p.canUndo, p.canRedo);
      // Project-level settings (moved from transport event)
      set({
        isRepeat: p.repeat,
        isMetronome: p.metronome.enabled,
        metronomeVolume: p.metronome.volume,
        barOffset: p.barOffset,
      });
    } else if (isTracksEvent(message)) {
      const p = message.payload as TracksEventPayload;
      // Convert WSTrack format to Track format
      const tracks: Record<number, import('../core/types').Track> = {};
      for (const t of p.tracks) {
        // Build flags bitfield from boolean fields
        let flags = 0;
        if (t.selected) flags |= 2; // SELECTED (TrackFlags.SELECTED = 2)
        if (t.mute) flags |= 8; // MUTED
        if (t.solo) flags |= 16; // SOLOED
        if (t.recArm) flags |= 64; // RECORD_ARMED
        if (t.recMon === 1) flags |= 128; // RECORD_MONITOR_ON
        if (t.recMon === 2) flags |= 256; // RECORD_MONITOR_AUTO
        if (!t.fxEnabled) flags |= 4; // HAS_FX (inverted - fxEnabled=false means disabled)

        tracks[t.idx] = {
          index: t.idx,
          name: t.name,
          color: t.color,
          volume: t.volume,
          pan: t.pan,
          flags,
          lastMeterPeak: 0,
          lastMeterPos: 0,
          clipped: false,
          width: 0,
          panMode: 0,
          sendCount: 0,
          receiveCount: 0,
          hwOutCount: 0,
        };
      }

      // Process meter data - update track objects with peak levels and clip state
      // WebSocket sends linear amplitude (1.0 = 0dB), use max of L/R for mono display
      if (p.meters && p.meters.length > 0) {
        for (const m of p.meters) {
          if (tracks[m.trackIdx]) {
            const peak = Math.max(m.peakL, m.peakR);
            tracks[m.trackIdx].lastMeterPeak = peak;
            tracks[m.trackIdx].lastMeterPos = peak;
            tracks[m.trackIdx].clipped = m.clipped;
          }
        }
      }

      set({ tracks, trackCount: p.tracks.length });
    } else if (isMarkersEvent(message)) {
      const p = message.payload as MarkersEventPayload;
      const markers: Marker[] = p.markers.map((m) => ({
        id: m.id,
        position: m.position,
        name: m.name,
        color: m.color || undefined,
      }));
      get().setMarkers(markers);
    } else if (isRegionsEvent(message)) {
      const p = message.payload as RegionsEventPayload;
      const regions: Region[] = p.regions.map((r) => ({
        id: r.id,
        start: r.start,
        end: r.end,
        name: r.name,
        color: r.color || undefined,
      }));
      get().setRegions(regions);
    } else if (isItemsEvent(message)) {
      const p = message.payload as ItemsEventPayload;
      get().setItems(p.items);
    } else if (message.event === 'reload') {
      // Hot reload - extension detected file change
      console.log('[Store] Reload event received, refreshing page...');
      window.location.reload();
    }
  },
}));

// Re-export slice types
export type { ConnectionSlice } from './slices/connectionSlice';
export type { TransportSlice } from './slices/transportSlice';
export type { ProjectSlice } from './slices/projectSlice';
export type { TracksSlice } from './slices/tracksSlice';
export type { RegionsSlice } from './slices/regionsSlice';
export type { MarkersSlice } from './slices/markersSlice';
export type { RegionEditSlice, TimelineMode, DragType, PendingRegionChange } from './slices/regionEditSlice';
export type { ItemsSlice } from './slices/itemsSlice';
export { makeItemKey, parseItemKey } from './slices/itemsSlice';

// Expose store on window for E2E tests (development only)
if (import.meta.env.DEV) {
  (window as unknown as { __REAPER_STORE__: typeof useReaperStore }).
    __REAPER_STORE__ = useReaperStore;
}
