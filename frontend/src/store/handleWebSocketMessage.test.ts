/**
 * Tests for handleWebSocketMessage — the contract between backend and frontend.
 *
 * Each test verifies: server sends event → store state updates correctly.
 * This is the highest-leverage test target: every roadmap feature flows through here.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { useReaperStore } from './index';
import { msg } from '../test';

// Import real engine singletons — the store holds references to these same objects,
// so vi.spyOn will intercept calls made from handleWebSocketMessage.
// (vi.mock doesn't work here because setup.ts imports the store before mocks are hoisted)
import { transportEngine } from '../core/TransportAnimationEngine';
import { transportSyncEngine } from '../core/TransportSyncEngine';

function handle(message: ReturnType<typeof msg.transport>) {
  useReaperStore.getState().handleWebSocketMessage(message);
}

describe('handleWebSocketMessage', () => {
  beforeEach(() => {
    // Ensure test mode is off so messages are processed
    useReaperStore.setState({ _testMode: false });
    vi.restoreAllMocks();

    // Spy on engine methods so we can assert delegation without side effects
    vi.spyOn(transportEngine, 'onServerUpdate').mockImplementation(() => {});
    vi.spyOn(transportEngine, 'onTickUpdate').mockImplementation(() => {});
    vi.spyOn(transportSyncEngine, 'onTransportEvent').mockImplementation(() => {});
    vi.spyOn(transportSyncEngine, 'onTickEvent').mockImplementation(() => {});
    vi.spyOn(transportSyncEngine, 'setTempoMarkers').mockImplementation(() => {});
    vi.spyOn(transportSyncEngine, 'onClockSyncResponse').mockImplementation(() => {});
  });

  // ===========================================================================
  // Test mode
  // ===========================================================================

  describe('test mode', () => {
    it('skips processing when _testMode is true', () => {
      useReaperStore.setState({ _testMode: true, playState: 0 });
      handle(msg.transport({ playState: 1 }));
      expect(useReaperStore.getState().playState).toBe(0);
    });
  });

  // ===========================================================================
  // Transport
  // ===========================================================================

  describe('transport event', () => {
    it('updates play state', () => {
      handle(msg.transport({ playState: 1 }));
      expect(useReaperStore.getState().playState).toBe(1);
    });

    it('updates position', () => {
      handle(msg.transport({ position: 42.5 }));
      expect(useReaperStore.getState().positionSeconds).toBe(42.5);
    });

    it('updates BPM', () => {
      handle(msg.transport({ bpm: 140 }));
      expect(useReaperStore.getState().bpm).toBe(140);
    });

    it('updates time signature', () => {
      handle(msg.transport({
        timeSignature: { numerator: 6, denominator: 8 },
      }));
      const s = useReaperStore.getState();
      expect(s.timeSignatureNumerator).toBe(6);
      expect(s.timeSignatureDenominator).toBe(8);
    });

    it('stores time selection when start !== end', () => {
      handle(msg.transport({
        timeSelection: { start: 10, end: 20 },
      }));
      const ts = useReaperStore.getState().timeSelection;
      expect(ts).toEqual({ startSeconds: 10, endSeconds: 20 });
    });

    it('clears time selection when start === end', () => {
      // First set a selection
      handle(msg.transport({ timeSelection: { start: 10, end: 20 } }));
      expect(useReaperStore.getState().timeSelection).not.toBeNull();

      // Then clear it
      handle(msg.transport({ timeSelection: { start: 0, end: 0 } }));
      expect(useReaperStore.getState().timeSelection).toBeNull();
    });

    it('updates position beats string', () => {
      handle(msg.transport({ positionBeats: '4.3.50' }));
      expect(useReaperStore.getState().positionBeats).toBe('4.3.50');
    });

    it('feeds transport animation engine', () => {
      handle(msg.transport({ position: 5, bpm: 130, playState: 1 }));
      expect(transportEngine.onServerUpdate).toHaveBeenCalledWith(
        expect.objectContaining({
          position: 5,
          bpm: 130,
          playState: 1,
        })
      );
    });

    it('feeds transport sync engine', () => {
      const payload = { playState: 1 as const, position: 5, bpm: 130 };
      handle(msg.transport(payload));
      expect(transportSyncEngine.onTransportEvent).toHaveBeenCalledWith(
        expect.objectContaining(payload)
      );
    });
  });

  // ===========================================================================
  // Transport Tick (lightweight position update)
  // ===========================================================================

  describe('transport tick event (tt)', () => {
    it('feeds sync engine with tick data', () => {
      handle(msg.transportTick({
        t: 1000, b: 4.5, bpm: 120, ts: [4, 4], bbt: '2.1.00',
      }));
      expect(transportSyncEngine.onTickEvent).toHaveBeenCalledWith(
        1000, 4.5, 120, [4, 4], '2.1.00'
      );
    });

    it('feeds animation engine with position and bbt', () => {
      handle(msg.transportTick({ p: 12.5, bbt: '7.1.00' }));
      expect(transportEngine.onTickUpdate).toHaveBeenCalledWith(12.5, '7.1.00');
    });
  });

  // ===========================================================================
  // Project
  // ===========================================================================

  describe('project event', () => {
    it('updates project name', () => {
      handle(msg.project({ projectName: 'My Song.rpp' }));
      expect(useReaperStore.getState().projectName).toBe('My Song.rpp');
    });

    it('updates undo/redo state', () => {
      handle(msg.project({
        canUndo: 'Set track volume',
        canRedo: 'Delete marker',
      }));
      const s = useReaperStore.getState();
      expect(s.reaperCanUndo).toBe('Set track volume');
      expect(s.reaperCanRedo).toBe('Delete marker');
    });

    it('updates dirty flag', () => {
      handle(msg.project({ isDirty: true }));
      expect(useReaperStore.getState().isProjectDirty).toBe(true);
    });

    it('updates repeat state', () => {
      handle(msg.project({ repeat: true }));
      expect(useReaperStore.getState().isRepeat).toBe(true);
    });

    it('updates metronome state', () => {
      handle(msg.project({
        metronome: { enabled: true, volume: 0.5, volumeDb: -6 },
      }));
      const s = useReaperStore.getState();
      expect(s.isMetronome).toBe(true);
      expect(s.metronomeVolume).toBe(0.5);
    });

    it('updates bar offset', () => {
      handle(msg.project({ barOffset: -4 }));
      expect(useReaperStore.getState().barOffset).toBe(-4);
    });

    it('updates memory warning', () => {
      handle(msg.project({ memoryWarning: true }));
      expect(useReaperStore.getState().memoryWarning).toBe(true);
    });

    it('updates master stereo state', () => {
      handle(msg.project({
        master: { stereoEnabled: false },
      }));
      expect(useReaperStore.getState().masterStereo).toBe(false);
    });
  });

  // ===========================================================================
  // Track Skeleton
  // ===========================================================================

  describe('trackSkeleton event', () => {
    it('sets skeleton track list', () => {
      handle(msg.trackSkeleton([
        { n: 'Drums', g: '{GUID-1}' },
        { n: 'Bass', g: '{GUID-2}' },
      ]));
      const skeleton = useReaperStore.getState().trackSkeleton;
      expect(skeleton).toHaveLength(2);
      expect(skeleton[0].n).toBe('Drums');
      expect(skeleton[1].n).toBe('Bass');
    });
  });

  // ===========================================================================
  // Tracks — the most complex handler (flag bitfield conversion)
  // ===========================================================================

  describe('tracks event', () => {
    it('converts WSTrack to Track record keyed by index', () => {
      handle(msg.tracks([
        { idx: 1, name: 'Track 1', g: '{GUID-1}' },
        { idx: 2, name: 'Track 2', g: '{GUID-2}' },
      ]));
      const tracks = useReaperStore.getState().tracks;
      expect(tracks[1]?.name).toBe('Track 1');
      expect(tracks[2]?.name).toBe('Track 2');
    });

    it('maps g field to guid', () => {
      handle(msg.tracks([{ idx: 1, g: '{MY-TRACK-GUID}' }]));
      expect(useReaperStore.getState().tracks[1]?.guid).toBe('{MY-TRACK-GUID}');
    });

    it('carries through sparse counts', () => {
      handle(msg.tracks([{
        idx: 1,
        fxCount: 3,
        sendCount: 2,
        receiveCount: 1,
        hwOutCount: 4,
      }]));
      const t = useReaperStore.getState().tracks[1];
      expect(t?.fxCount).toBe(3);
      expect(t?.sendCount).toBe(2);
      expect(t?.receiveCount).toBe(1);
      expect(t?.hwOutCount).toBe(4);
    });

    it('sets totalTracks from payload total', () => {
      handle(msg.tracks([{ idx: 1 }], 10));
      expect(useReaperStore.getState().totalTracks).toBe(10);
    });

    // Flag bitfield tests — these are the most critical
    describe('flag bitfield conversion', () => {
      it('sets SELECTED flag (bit 2) when selected=true', () => {
        handle(msg.tracks([{ idx: 1, selected: true }]));
        expect(useReaperStore.getState().tracks[1]?.flags & 2).toBe(2);
      });

      it('sets MUTED flag (bit 8) when mute=true', () => {
        handle(msg.tracks([{ idx: 1, mute: true }]));
        expect(useReaperStore.getState().tracks[1]?.flags & 8).toBe(8);
      });

      it('sets SOLOED flag (bit 16) when solo > 0', () => {
        handle(msg.tracks([{ idx: 1, solo: 1 }]));
        expect(useReaperStore.getState().tracks[1]?.flags & 16).toBe(16);
      });

      it('sets RECORD_ARMED flag (bit 64) when recArm=true', () => {
        handle(msg.tracks([{ idx: 1, recArm: true }]));
        expect(useReaperStore.getState().tracks[1]?.flags & 64).toBe(64);
      });

      it('sets RECORD_MONITOR_ON flag (bit 128) when recMon=1', () => {
        handle(msg.tracks([{ idx: 1, recMon: 1 }]));
        const flags = useReaperStore.getState().tracks[1]?.flags ?? 0;
        expect(flags & 128).toBe(128);
        expect(flags & 256).toBe(0); // AUTO should not be set
      });

      it('sets RECORD_MONITOR_AUTO flag (bit 256) when recMon=2', () => {
        handle(msg.tracks([{ idx: 1, recMon: 2 }]));
        const flags = useReaperStore.getState().tracks[1]?.flags ?? 0;
        expect(flags & 256).toBe(256);
        expect(flags & 128).toBe(0); // ON should not be set
      });

      it('sets HAS_FX flag (bit 4) when fxEnabled=false (inverted!)', () => {
        handle(msg.tracks([{ idx: 1, fxEnabled: false }]));
        expect(useReaperStore.getState().tracks[1]?.flags & 4).toBe(4);
      });

      it('does NOT set HAS_FX flag when fxEnabled=true', () => {
        handle(msg.tracks([{ idx: 1, fxEnabled: true }]));
        expect(useReaperStore.getState().tracks[1]?.flags & 4).toBe(0);
      });

      it('combines multiple flags correctly', () => {
        handle(msg.tracks([{
          idx: 1,
          selected: true,    // 2
          mute: true,        // 8
          recArm: true,      // 64
          fxEnabled: false,  // 4
        }]));
        const flags = useReaperStore.getState().tracks[1]?.flags ?? 0;
        expect(flags & 2).toBe(2);
        expect(flags & 4).toBe(4);
        expect(flags & 8).toBe(8);
        expect(flags & 64).toBe(64);
      });

      it('has no flags set for default track', () => {
        handle(msg.tracks([{ idx: 1 }])); // defaults: mute=false, solo=0, etc.
        expect(useReaperStore.getState().tracks[1]?.flags).toBe(0);
      });
    });

    it('passes recInput when present', () => {
      handle(msg.tracks([{ idx: 1, recArm: true, recInput: 1024 }]));
      expect(useReaperStore.getState().tracks[1]?.recInput).toBe(1024);
    });
  });

  // ===========================================================================
  // Meters (non-standard envelope — m at root, NOT inside payload)
  // ===========================================================================

  describe('meters event', () => {
    it('calls updateMeters with GUID-keyed meter data', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'updateMeters');
      handle(msg.meters({
        '{GUID-1}': { i: 1, l: 0.75, r: 0.68, c: false },
      }));
      expect(spy).toHaveBeenCalledWith({
        '{GUID-1}': { i: 1, l: 0.75, r: 0.68, c: false },
      });
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Markers
  // ===========================================================================

  describe('markers event', () => {
    it('maps WSMarker to Marker format', () => {
      handle(msg.markers([
        { id: 0, position: 5, name: 'Verse', color: 0xff0000, positionBeats: 10, positionBars: '3.1.00' },
        { id: 1, position: 15, name: 'Chorus', color: 0 },
      ]));
      const markers = useReaperStore.getState().markers;
      expect(markers).toHaveLength(2);
      expect(markers[0]).toEqual(expect.objectContaining({
        id: 0,
        position: 5,
        name: 'Verse',
        color: 0xff0000,
      }));
    });

    it('converts color 0 to undefined', () => {
      handle(msg.markers([{ id: 0, color: 0 }]));
      expect(useReaperStore.getState().markers[0]?.color).toBeUndefined();
    });
  });

  // ===========================================================================
  // Regions
  // ===========================================================================

  describe('regions event', () => {
    it('maps WSRegion to Region format with bar/beat fields', () => {
      handle(msg.regions([{
        id: 0, start: 0, end: 10, name: 'Intro',
        startBeats: 0, endBeats: 20,
        startBars: '1.1.00', endBars: '5.1.00',
        lengthBars: '4.0.00',
        color: 0x00ff00,
      }]));
      const regions = useReaperStore.getState().regions;
      expect(regions).toHaveLength(1);
      expect(regions[0]).toEqual(expect.objectContaining({
        id: 0, start: 0, end: 10, name: 'Intro',
        startBeats: 0, endBeats: 20,
        startBars: '1.1.00', endBars: '5.1.00',
        lengthBars: '4.0.00',
        color: 0x00ff00,
      }));
    });

    it('converts color 0 to undefined', () => {
      handle(msg.regions([{ id: 0, color: 0 }]));
      expect(useReaperStore.getState().regions[0]?.color).toBeUndefined();
    });
  });

  // ===========================================================================
  // Items
  // ===========================================================================

  describe('items event', () => {
    it('sets items via setItems', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'setItems');
      handle(msg.items([
        { guid: '{ITEM-1}', trackIdx: 1, position: 0, length: 5 },
        { guid: '{ITEM-2}', trackIdx: 2, position: 10, length: 3 },
      ]));
      expect(spy).toHaveBeenCalled();
      const args = spy.mock.calls[0][0];
      expect(args).toHaveLength(2);
      expect(args[0].guid).toBe('{ITEM-1}');
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // FX State (broadcast)
  // ===========================================================================

  describe('fx_state event', () => {
    it('sets FX via setFx', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'setFx');
      handle(msg.fxState([
        { trackIdx: 1, fxIndex: 0, name: 'ReaEQ', enabled: true },
      ]));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Sends State (broadcast)
  // ===========================================================================

  describe('sends_state event', () => {
    it('sets sends via setSends', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'setSends');
      handle(msg.sendsState([
        { srcTrackIdx: 1, destTrackIdx: 3, volume: 0.8 },
      ]));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Routing State (per-client subscription)
  // ===========================================================================

  describe('routing_state event', () => {
    it('calls handleRoutingStateEvent', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handleRoutingStateEvent');
      handle(msg.routingState({
        trackGuid: '{GUID-1}',
        sends: [{ sendIndex: 0, destName: 'Bus', volume: 1, pan: 0, muted: false, mode: 0 }],
        receives: [],
        hwOutputs: [],
      }));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Action Toggle State
  // ===========================================================================

  describe('actionToggleState event', () => {
    it('calls updateToggleStates with changes', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'updateToggleStates');
      handle(msg.actionToggleState([
        { s: 0, c: 40012, v: 1 },
        { s: 0, c: 40013, v: 0 },
      ]));
      expect(spy).toHaveBeenCalledWith([
        { s: 0, c: 40012, v: 1 },
        { s: 0, c: 40013, v: 0 },
      ]);
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Tempo Map
  // ===========================================================================

  describe('tempoMap event', () => {
    it('sets tempo markers in store', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'setTempoMarkers');
      handle(msg.tempoMap([
        { position: 0, bpm: 120 },
        { position: 60, bpm: 140 },
      ]));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });

    it('forwards to transport sync engine', () => {
      handle(msg.tempoMap([{ position: 0, bpm: 120 }]));
      expect(transportSyncEngine.setTempoMarkers).toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Project Notes Changed
  // ===========================================================================

  describe('projectNotesChanged event', () => {
    it('calls handleExternalChange with hash', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handleExternalChange');
      handle(msg.projectNotesChanged('abc123'));
      expect(spy).toHaveBeenCalledWith('abc123');
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Playlist
  // ===========================================================================

  describe('playlist event', () => {
    it('calls setPlaylistState with full payload', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'setPlaylistState');
      handle(msg.playlist({
        playlists: [{
          name: 'Setlist 1',
          entries: [{ regionId: 0, loopCount: 1 }],
          stopAfterLast: false,
        }],
        activePlaylistIndex: 0,
        currentEntryIndex: 0,
        loopsRemaining: 1,
        currentLoopIteration: 1,
        isPlaylistActive: true,
        isPaused: false,
        advanceAfterLoop: false,
      }));
      expect(spy).toHaveBeenCalledWith(
        expect.objectContaining({
          isPlaylistActive: true,
          activePlaylistIndex: 0,
        })
      );
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Peaks (tile-based)
  // ===========================================================================

  describe('peaks event', () => {
    it('calls handlePeaksEvent with tile data', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handlePeaksEvent');
      handle(msg.peaks([{
        takeGuid: '{TAKE-1}',
        lod: 5,
        tileIndex: 0,
        channels: 2,
      }]));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // FX Chain (per-client subscription)
  // ===========================================================================

  describe('trackFxChain event', () => {
    it('calls handleFxChainEvent', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handleFxChainEvent');
      handle(msg.fxChain('{GUID-1}', [
        { fxGuid: '{FX-1}', name: 'ReaComp', fxIndex: 0 },
      ]));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // FX Params (per-client subscription)
  // ===========================================================================

  describe('trackFxParams event', () => {
    it('calls handleFxParamsEvent with param values', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handleFxParamsEvent');
      handle(msg.fxParams({
        trackGuid: '{GUID-1}',
        fxGuid: '{FX-1}',
        paramCount: 5,
        nameHash: 99999,
        values: { '0': [0.5, '-6.0 dB'], '1': [1.0, '20000 Hz'] },
      }));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  describe('trackFxParamsError event', () => {
    it('calls handleFxParamsError', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handleFxParamsError');
      handle(msg.fxParamsError('FX_NOT_FOUND'));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Tuner
  // ===========================================================================

  describe('tuner event', () => {
    it('calls handleTunerEvent with pitch data', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handleTunerEvent');
      handle(msg.tuner({
        freq: 440,
        note: 69,
        noteName: 'A',
        octave: 4,
        cents: 2,
        conf: 0.98,
        inTune: true,
      }));
      expect(spy).toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  describe('tunerError event', () => {
    it('calls handleTunerError with error string from payload', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'handleTunerError');
      handle(msg.tunerError('TUNER_NOT_FOUND'));
      expect(spy).toHaveBeenCalledWith('TUNER_NOT_FOUND');
      spy.mockRestore();
    });
  });

  // ===========================================================================
  // Clock Sync Response
  // ===========================================================================

  describe('clockSyncResponse', () => {
    it('forwards to transport sync engine', () => {
      handle(msg.clockSyncResponse({ t0: 1000, t1: 1005, t2: 1006 }));
      expect(transportSyncEngine.onClockSyncResponse).toHaveBeenCalledWith(
        expect.objectContaining({ t0: 1000, t1: 1005, t2: 1006 })
      );
    });

    it('does not process as event (early return)', () => {
      // clockSyncResponse is not an event message — it should return early
      // and not trigger any event handlers. Verify by checking that play state
      // (which would be set by a transport event) is unchanged.
      useReaperStore.setState({ playState: 0 });
      handle(msg.clockSyncResponse());
      expect(useReaperStore.getState().playState).toBe(0);
    });
  });

  // ===========================================================================
  // Reload
  // ===========================================================================

  describe('reload event', () => {
    it('calls window.location.reload', () => {
      const reloadMock = vi.fn();
      Object.defineProperty(window, 'location', {
        value: { reload: reloadMock },
        writable: true,
        configurable: true,
      });
      handle(msg.reload());
      expect(reloadMock).toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Non-event messages are ignored
  // ===========================================================================

  describe('non-event messages', () => {
    it('ignores response messages', () => {
      const spy = vi.spyOn(useReaperStore.getState(), 'setRegions');
      handle({
        type: 'response',
        id: '123',
        success: true,
      } as any);
      expect(spy).not.toHaveBeenCalled();
      spy.mockRestore();
    });
  });
});
