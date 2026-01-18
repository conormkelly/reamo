/**
 * FX Chain state slice
 * Manages per-track FX chain data pushed by backend at 30Hz
 *
 * Used by FxModal for real-time updates when FX is added/removed/modified.
 * Only one track can be subscribed at a time (modal can only show one track).
 * Follows the same pattern as routingSlice.
 */

import type { StateCreator } from 'zustand';
import type { FxChainEventPayload, WSFxChainSlot } from '../../core/WebSocketTypes';

export interface FxChainSlice {
  // Subscription state
  /** GUID of the currently subscribed track (null = not subscribed) */
  fxChainSubscribedGuid: string | null;

  // Data state
  /** Current FX chain for subscribed track */
  fxChainList: WSFxChainSlot[];

  // Actions
  /** Set subscription state (call before sending trackFx/subscribe command) */
  setFxChainSubscription: (trackGuid: string | null) => void;
  /** Handle incoming trackFxChain event from backend */
  handleFxChainEvent: (payload: FxChainEventPayload) => void;
  /** Clear subscription and data (call after sending trackFx/unsubscribe command) */
  clearFxChainSubscription: () => void;
}

export const createFxChainSlice: StateCreator<FxChainSlice, [], [], FxChainSlice> = (set, get) => ({
  // Initial state
  fxChainSubscribedGuid: null,
  fxChainList: [],

  // Actions
  setFxChainSubscription: (trackGuid) =>
    set({
      fxChainSubscribedGuid: trackGuid,
      // Clear old data when subscription changes
      fxChainList: [],
    }),

  handleFxChainEvent: (payload) => {
    // Only update if the event is for our subscribed track
    const currentGuid = get().fxChainSubscribedGuid;
    if (!currentGuid || payload.trackGuid !== currentGuid) {
      return;
    }

    set({
      fxChainList: payload.fx,
    });
  },

  clearFxChainSubscription: () =>
    set({
      fxChainSubscribedGuid: null,
      fxChainList: [],
    }),
});
