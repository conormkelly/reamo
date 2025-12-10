/**
 * Main Zustand store
 * Combines all slices and provides response handling
 */

import { create } from 'zustand';
import { createConnectionSlice, type ConnectionSlice } from './slices/connectionSlice';
import { createTransportSlice, type TransportSlice } from './slices/transportSlice';
import { createTracksSlice, type TracksSlice } from './slices/tracksSlice';
import { createRegionsSlice, type RegionsSlice } from './slices/regionsSlice';
import type { ParsedResponse, Region } from '../core/types';

// Combined store type
export type ReaperStore = ConnectionSlice & TransportSlice & TracksSlice & RegionsSlice & {
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

  // Handle incoming responses from REAPER
  handleResponses: (responses: ParsedResponse[]) => {
    // Collect regions from REGION_LIST responses
    const collectedRegions: Region[] = [];
    let inRegionList = false;

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
