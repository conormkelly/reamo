/**
 * Main Zustand store
 * Combines all slices and provides response handling
 */

import { create } from 'zustand';
import { createConnectionSlice, type ConnectionSlice } from './slices/connectionSlice';
import { createTransportSlice, type TransportSlice } from './slices/transportSlice';
import { createTracksSlice, type TracksSlice } from './slices/tracksSlice';
import type { ParsedResponse } from '../core/types';

// Combined store type
export type ReaperStore = ConnectionSlice & TransportSlice & TracksSlice & {
  // Response handler action
  handleResponses: (responses: ParsedResponse[]) => void;
};

// Create the combined store
export const useReaperStore = create<ReaperStore>()((set, get, store) => ({
  // Spread all slices
  ...createConnectionSlice(set, get, store),
  ...createTransportSlice(set, get, store),
  ...createTracksSlice(set, get, store),

  // Handle incoming responses from REAPER
  handleResponses: (responses: ParsedResponse[]) => {
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

        case 'GET/REPEAT':
          get().setRepeat(response.value);
          break;

        // Add more response handlers as needed
        default:
          // Ignore unhandled responses
          break;
      }
    }
  },
}));

// Re-export slice types
export type { ConnectionSlice } from './slices/connectionSlice';
export type { TransportSlice } from './slices/transportSlice';
export type { TracksSlice } from './slices/tracksSlice';
