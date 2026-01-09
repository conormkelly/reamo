/**
 * Modal state slice
 * Centralizes Timeline-related modal state for decoupling
 * Uses discriminated union for type-safe modal data
 */

import type { StateCreator } from 'zustand';
import type { Marker, Region } from '../../core/types';

// Discriminated union for modal state
export type ModalState =
  | { type: 'none' }
  | { type: 'markerEdit'; marker: Marker }
  | { type: 'deleteRegion'; region: Region; regionId: number }
  | { type: 'addRegion' }
  | { type: 'makeSelection' };

export interface ModalSlice {
  // State
  modal: ModalState;

  // Actions
  openMarkerEditModal: (marker: Marker) => void;
  openDeleteRegionModal: (region: Region, regionId: number) => void;
  openAddRegionModal: () => void;
  openMakeSelectionModal: () => void;
  closeModal: () => void;
}

export const createModalSlice: StateCreator<ModalSlice> = (set) => ({
  // Initial state
  modal: { type: 'none' },

  // Actions
  openMarkerEditModal: (marker) => set({ modal: { type: 'markerEdit', marker } }),
  openDeleteRegionModal: (region, regionId) => set({ modal: { type: 'deleteRegion', region, regionId } }),
  openAddRegionModal: () => set({ modal: { type: 'addRegion' } }),
  openMakeSelectionModal: () => set({ modal: { type: 'makeSelection' } }),
  closeModal: () => set({ modal: { type: 'none' } }),
});
