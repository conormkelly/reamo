/**
 * Tests for sendsStateSlice + routingSlice — sends and routing state management.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '../index';
import { getSendsFromTrack, getSendsToTrack } from './sendsStateSlice';
import { msg } from '../../test';

describe('sendsStateSlice', () => {
  beforeEach(() => {
    useReaperStore.setState({ sends: [] });
  });

  it('sets sends list', () => {
    useReaperStore.getState().setSends([
      msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 3 }),
      msg.wsSendSlot({ srcTrackIdx: 2, destTrackIdx: 3 }),
    ]);
    expect(useReaperStore.getState().sends).toHaveLength(2);
  });

  it('replaces sends on update', () => {
    useReaperStore.getState().setSends([msg.wsSendSlot()]);
    useReaperStore.getState().setSends([]);
    expect(useReaperStore.getState().sends).toHaveLength(0);
  });
});

describe('getSendsFromTrack helper', () => {
  it('filters sends by source track', () => {
    const sends = [
      msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 3 }),
      msg.wsSendSlot({ srcTrackIdx: 2, destTrackIdx: 3 }),
      msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 4 }),
    ];
    expect(getSendsFromTrack(sends, 1)).toHaveLength(2);
    expect(getSendsFromTrack(sends, 2)).toHaveLength(1);
    expect(getSendsFromTrack(sends, 99)).toHaveLength(0);
  });
});

describe('getSendsToTrack helper', () => {
  it('filters sends by destination track', () => {
    const sends = [
      msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 3 }),
      msg.wsSendSlot({ srcTrackIdx: 2, destTrackIdx: 3 }),
      msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 4 }),
    ];
    expect(getSendsToTrack(sends, 3)).toHaveLength(2);
    expect(getSendsToTrack(sends, 4)).toHaveLength(1);
  });
});

describe('routingSlice', () => {
  beforeEach(() => {
    useReaperStore.getState().clearRoutingSubscription();
  });

  describe('setRoutingSubscription', () => {
    it('sets subscription and clears old data', () => {
      // Set some stale data first
      useReaperStore.setState({
        routingSends: [{ sendIndex: 0, destName: 'Stale', volume: 1, pan: 0, muted: false, mode: 0 }],
      });

      useReaperStore.getState().setRoutingSubscription('{GUID-1}');
      const s = useReaperStore.getState();
      expect(s.routingSubscribedGuid).toBe('{GUID-1}');
      expect(s.routingSends).toEqual([]);
      expect(s.routingReceives).toEqual([]);
      expect(s.routingHwOutputs).toEqual([]);
    });
  });

  describe('handleRoutingStateEvent', () => {
    it('updates routing data for subscribed track', () => {
      useReaperStore.getState().setRoutingSubscription('{GUID-1}');
      useReaperStore.getState().handleRoutingStateEvent({
        trackGuid: '{GUID-1}',
        sends: [{ sendIndex: 0, destName: 'Bus A', volume: 1, pan: 0, muted: false, mode: 0 }],
        receives: [{ receiveIndex: 0, srcName: 'Guitar', volume: 1, pan: 0, muted: false, mode: 0 }],
        hwOutputs: [{ hwIdx: 0, destChannel: 0, volume: 1, pan: 0, muted: false, mode: 0 }],
      });
      const s = useReaperStore.getState();
      expect(s.routingSends).toHaveLength(1);
      expect(s.routingReceives).toHaveLength(1);
      expect(s.routingHwOutputs).toHaveLength(1);
    });

    it('ignores event for wrong track', () => {
      useReaperStore.getState().setRoutingSubscription('{GUID-1}');
      useReaperStore.getState().handleRoutingStateEvent({
        trackGuid: '{GUID-OTHER}',
        sends: [{ sendIndex: 0, destName: 'Ignored', volume: 1, pan: 0, muted: false, mode: 0 }],
        receives: [],
        hwOutputs: [],
      });
      expect(useReaperStore.getState().routingSends).toEqual([]);
    });

    it('ignores event when not subscribed', () => {
      useReaperStore.getState().handleRoutingStateEvent({
        trackGuid: '{GUID-1}',
        sends: [{ sendIndex: 0, destName: 'Ignored', volume: 1, pan: 0, muted: false, mode: 0 }],
        receives: [],
        hwOutputs: [],
      });
      expect(useReaperStore.getState().routingSends).toEqual([]);
    });
  });

  describe('clearRoutingSubscription', () => {
    it('clears subscription and all data', () => {
      useReaperStore.getState().setRoutingSubscription('{GUID-1}');
      useReaperStore.getState().handleRoutingStateEvent({
        trackGuid: '{GUID-1}',
        sends: [{ sendIndex: 0, destName: 'Bus', volume: 1, pan: 0, muted: false, mode: 0 }],
        receives: [],
        hwOutputs: [],
      });
      useReaperStore.getState().clearRoutingSubscription();
      const s = useReaperStore.getState();
      expect(s.routingSubscribedGuid).toBeNull();
      expect(s.routingSends).toEqual([]);
    });
  });
});
