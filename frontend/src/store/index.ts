/**
 * Main Zustand store
 * Combines all slices and provides response handling
 */

import { create } from 'zustand';
import { createConnectionSlice, type ConnectionSlice } from './slices/connectionSlice';
import { createTransportSlice, type TransportSlice } from './slices/transportSlice';
import { createTracksSlice, type TracksSlice } from './slices/tracksSlice';
import { createRegionsSlice, type RegionsSlice } from './slices/regionsSlice';
import { createMarkersSlice, type MarkersSlice } from './slices/markersSlice';
import { createRegionEditSlice, type RegionEditSlice } from './slices/regionEditSlice';
import type { ParsedResponse, Region, Marker, CommandState } from '../core/types';
import { ActionCommands, SWSCommands } from '../core/types';
import type {
  ServerMessage,
  TransportEventPayload,
  TracksEventPayload,
  MarkersEventPayload,
  RegionsEventPayload,
} from '../core/WebSocketTypes';
import {
  isEventMessage,
  isTransportEvent,
  isTracksEvent,
  isMarkersEvent,
  isRegionsEvent,
} from '../core/WebSocketTypes';

// Combined store type
export type ReaperStore = ConnectionSlice & TransportSlice & TracksSlice & RegionsSlice & MarkersSlice & RegionEditSlice & {
  // Response handler action (legacy HTTP)
  handleResponses: (responses: ParsedResponse[]) => void;
  // WebSocket message handler
  handleWebSocketMessage: (message: ServerMessage) => void;
};

// Create the combined store
export const useReaperStore = create<ReaperStore>()((set, get, store) => ({
  // Spread all slices
  ...createConnectionSlice(set, get, store),
  ...createTransportSlice(set, get, store),
  ...createTracksSlice(set, get, store),
  ...createRegionsSlice(set, get, store),
  ...createMarkersSlice(set, get, store),
  ...createRegionEditSlice(set, get, store),

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

        case 'EXTSTATE': {
          const extState = response.data;
          // Check for Reamo region script installation flag
          if (extState.section === 'Reamo' && extState.key === 'script_installed') {
            get().setLuaScriptInstalled(extState.value === '1');
            get().setLuaScriptChecked(true);
          }
          // Check for Reamo marker script installation flag
          if (extState.section === 'Reamo' && extState.key === 'marker_script_installed') {
            get().setMarkerScriptInstalled(extState.value === '1');
            get().setMarkerScriptChecked(true);
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
    if (!isEventMessage(message)) return;

    if (isTransportEvent(message)) {
      const p = message.payload as TransportEventPayload;
      // REAPER's BPM is in denominator beats per minute (e.g., eighths for 6/8)
      // Normalize to quarter-note BPM for consistent display
      // For 4/4: bpm * (4/4) = no change
      // For 6/8: bpm * (4/8) = bpm * 0.5 (180 eighth-note BPM → 90 quarter-note BPM)
      const normalizedBpm = p.bpm * (4 / p.timeSignature.denominator);
      set({
        playState: p.playState,
        positionSeconds: p.position,
        positionBeats: p.positionBeats,
        bpm: normalizedBpm,
        timeSignatureNumerator: p.timeSignature.numerator,
        timeSignatureDenominator: p.timeSignature.denominator,
        isRepeat: p.repeat,
        isMetronome: p.metronome.enabled,
        metronomeVolume: p.metronome.volume,
        // Convert time selection from seconds to beats for compatibility
        // TODO: Simplify - store seconds directly, convert in UI if needed
        timeSelection: p.timeSelection.start !== p.timeSelection.end
          ? {
              startBeats: p.timeSelection.start * (normalizedBpm / 60),
              endBeats: p.timeSelection.end * (normalizedBpm / 60),
            }
          : null,
        barOffset: p.barOffset ?? 0,
      });
    } else if (isTracksEvent(message)) {
      const p = message.payload as TracksEventPayload;
      // Convert WSTrack format to Track format
      const tracks: Record<number, import('../core/types').Track> = {};
      for (const t of p.tracks) {
        // Build flags bitfield from boolean fields
        let flags = 0;
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
          width: 0,
          panMode: 0,
          sendCount: 0,
          receiveCount: 0,
          hwOutCount: 0,
        };
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
export type { TracksSlice } from './slices/tracksSlice';
export type { RegionsSlice } from './slices/regionsSlice';
export type { MarkersSlice } from './slices/markersSlice';
export type { RegionEditSlice, TimelineMode, DragType, PendingRegionChange } from './slices/regionEditSlice';

// Expose store on window for E2E tests (development only)
if (import.meta.env.DEV) {
  (window as unknown as { __REAPER_STORE__: typeof useReaperStore }).
    __REAPER_STORE__ = useReaperStore;
}
