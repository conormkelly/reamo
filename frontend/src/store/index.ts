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

// Combined store type
export type ReaperStore = ConnectionSlice & TransportSlice & TracksSlice & RegionsSlice & MarkersSlice & RegionEditSlice & {
  // Response handler action
  handleResponses: (responses: ParsedResponse[]) => void;
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
