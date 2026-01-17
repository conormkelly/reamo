/**
 * Routing state slice
 * Manages per-track routing data (sends, hw outputs) pushed by backend at 30Hz
 *
 * Used by RoutingModal for real-time updates during fader drags.
 * Only one track can be subscribed at a time (modal can only show one track).
 */

import type { StateCreator } from 'zustand';
import type { RoutingStateEventPayload, WSRoutingSend, WSRoutingReceive, WSRoutingHwOutput } from '../../core/WebSocketTypes';

export interface RoutingSlice {
  // Subscription state
  /** GUID of the currently subscribed track (null = not subscribed) */
  routingSubscribedGuid: string | null;

  // Data state
  /** Current sends for subscribed track */
  routingSends: WSRoutingSend[];
  /** Current receives for subscribed track */
  routingReceives: WSRoutingReceive[];
  /** Current hw outputs for subscribed track */
  routingHwOutputs: WSRoutingHwOutput[];

  // Actions
  /** Set subscription state (call before sending routing/subscribe command) */
  setRoutingSubscription: (trackGuid: string | null) => void;
  /** Handle incoming routing_state event from backend */
  handleRoutingStateEvent: (payload: RoutingStateEventPayload) => void;
  /** Clear subscription and data (call after sending routing/unsubscribe command) */
  clearRoutingSubscription: () => void;
}

export const createRoutingSlice: StateCreator<RoutingSlice, [], [], RoutingSlice> = (set, get) => ({
  // Initial state
  routingSubscribedGuid: null,
  routingSends: [],
  routingReceives: [],
  routingHwOutputs: [],

  // Actions
  setRoutingSubscription: (trackGuid) =>
    set({
      routingSubscribedGuid: trackGuid,
      // Clear old data when subscription changes
      routingSends: [],
      routingReceives: [],
      routingHwOutputs: [],
    }),

  handleRoutingStateEvent: (payload) => {
    // Only update if the event is for our subscribed track
    const currentGuid = get().routingSubscribedGuid;
    if (!currentGuid || payload.trackGuid !== currentGuid) {
      return;
    }

    set({
      routingSends: payload.sends,
      routingReceives: payload.receives,
      routingHwOutputs: payload.hwOutputs,
    });
  },

  clearRoutingSubscription: () =>
    set({
      routingSubscribedGuid: null,
      routingSends: [],
      routingReceives: [],
      routingHwOutputs: [],
    }),
});
