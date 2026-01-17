/**
 * Routing state slice
 * Manages per-track routing data (sends, hw outputs) pushed by backend at 30Hz
 *
 * Used by RoutingModal for real-time updates during fader drags.
 * Only one track can be subscribed at a time (modal can only show one track).
 */

import type { StateCreator } from 'zustand';
import type { RoutingStateEventPayload, WSRoutingSend, WSRoutingHwOutput } from '../../core/WebSocketTypes';

export interface RoutingSlice {
  // Subscription state
  /** GUID of the currently subscribed track (null = not subscribed) */
  routingSubscribedGuid: string | null;

  // Data state
  /** Current sends for subscribed track */
  routingSends: WSRoutingSend[];
  /** Current hw outputs for subscribed track */
  routingHwOutputs: WSRoutingHwOutput[];
  /** Receive count for subscribed track (full data coming later) */
  routingReceiveCount: number;

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
  routingHwOutputs: [],
  routingReceiveCount: 0,

  // Actions
  setRoutingSubscription: (trackGuid) =>
    set({
      routingSubscribedGuid: trackGuid,
      // Clear old data when subscription changes
      routingSends: [],
      routingHwOutputs: [],
      routingReceiveCount: 0,
    }),

  handleRoutingStateEvent: (payload) => {
    // Only update if the event is for our subscribed track
    const currentGuid = get().routingSubscribedGuid;
    if (!currentGuid || payload.trackGuid !== currentGuid) {
      return;
    }

    set({
      routingSends: payload.sends,
      routingHwOutputs: payload.hwOutputs,
      routingReceiveCount: payload.receiveCount,
    });
  },

  clearRoutingSubscription: () =>
    set({
      routingSubscribedGuid: null,
      routingSends: [],
      routingHwOutputs: [],
      routingReceiveCount: 0,
    }),
});
