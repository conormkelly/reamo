/**
 * WebSocket Message Factories for Tests
 *
 * Reusable factory functions for creating valid ServerMessage objects
 * with sensible defaults and overridable fields.
 *
 * Usage:
 *   import { msg } from '@/test'
 *   const message = msg.transport({ playState: 1, position: 5.0 })
 *   store.handleWebSocketMessage(message)
 */

import type {
  ServerMessage,
  EventMessage,
  ClockSyncResponse,
  TransportEventPayload,
  TransportTickEventPayload,
  ProjectEventPayload,
  TrackSkeletonEventPayload,
  TracksEventPayload,
  WSTrack,
  MeterData,
  MarkersEventPayload,
  WSMarker,
  RegionsEventPayload,
  WSRegion,
  ItemsEventPayload,
  WSItem,
  FxStateEventPayload,
  WSFxSlot,
  SendsStateEventPayload,
  WSSendSlot,
  RoutingStateEventPayload,
  ActionToggleStateEventPayload,
  ToggleStateChange,
  TempoMapEventPayload,
  WSTempoMarker,
  ProjectNotesChangedEventPayload,
  PlaylistEventPayload,
  PeaksEventPayload,
  PeaksTile,
  FxChainEventPayload,
  WSFxChainSlot,
  FxParamsEventPayload,
  FxParamsErrorEventPayload,
  TunerEventPayload,
  TunerErrorEventPayload,
  SkeletonTrack,
} from '../core/WebSocketTypes';

// =============================================================================
// Helper: wrap payload as EventMessage
// =============================================================================

function event<T>(eventType: string, payload: T): ServerMessage {
  return { type: 'event', event: eventType, payload } as EventMessage;
}

// =============================================================================
// Transport
// =============================================================================

const TRANSPORT_DEFAULTS: TransportEventPayload = {
  playState: 0,
  position: 0,
  positionBeats: '1.1.00',
  cursorPosition: 0,
  bpm: 120,
  timeSignature: { numerator: 4, denominator: 4 },
  timeSelection: { start: 0, end: 0 },
};

function transport(overrides?: Partial<TransportEventPayload>): ServerMessage {
  return event('transport', { ...TRANSPORT_DEFAULTS, ...overrides });
}

// =============================================================================
// Transport Tick (lightweight position update during playback)
// =============================================================================

function transportTick(overrides?: Partial<TransportTickEventPayload>): ServerMessage {
  return event('tt', {
    p: 0,
    t: Date.now(),
    b: 0,
    bpm: 120,
    ts: [4, 4] as [number, number],
    bbt: '1.1.00',
    ...overrides,
  });
}

// =============================================================================
// Project
// =============================================================================

const PROJECT_DEFAULTS: ProjectEventPayload = {
  canUndo: null,
  canRedo: null,
  stateChangeCount: 1,
  projectName: 'Test Project.rpp',
  repeat: false,
  metronome: { enabled: false, volume: 0.25, volumeDb: -12 },
  countIn: { playback: false, recording: false },
  preRoll: { playback: false, recording: false },
  master: { stereoEnabled: true },
  projectLength: 300,
  barOffset: 0,
  isDirty: false,
  recordMode: 0,
  memoryWarning: false,
};

function project(overrides?: Partial<ProjectEventPayload>): ServerMessage {
  return event('project', { ...PROJECT_DEFAULTS, ...overrides });
}

// =============================================================================
// Track Skeleton
// =============================================================================

function skeletonTrack(overrides?: Partial<SkeletonTrack>): SkeletonTrack {
  return {
    n: 'Track 1',
    g: '{AAAA-BBBB-CCCC-DDDD}',
    m: false,
    sl: null,
    sel: false,
    r: false,
    fd: 0,
    sc: 0,
    hc: 0,
    cl: false,
    ic: 0,
    fm: 0,
    c: 0,
    ...overrides,
  };
}

function trackSkeleton(tracks: Partial<SkeletonTrack>[]): ServerMessage {
  return event('trackSkeleton', {
    tracks: tracks.map(t => skeletonTrack(t)),
  } satisfies TrackSkeletonEventPayload);
}

// =============================================================================
// Tracks
// =============================================================================

function wsTrack(overrides?: Partial<WSTrack>): WSTrack {
  return {
    idx: 1,
    g: '{AAAA-BBBB-CCCC-DDDD}',
    name: 'Track 1',
    color: 0,
    volume: 1.0,
    pan: 0,
    mute: false,
    solo: 0,
    recArm: false,
    recMon: 0,
    fxEnabled: true,
    selected: false,
    fxCount: 0,
    sendCount: 0,
    receiveCount: 0,
    hwOutCount: 0,
    ...overrides,
  };
}

function tracks(trackList: Partial<WSTrack>[], total?: number): ServerMessage {
  const built = trackList.map(t => wsTrack(t));
  return event('tracks', {
    total: total ?? built.length,
    tracks: built,
  } satisfies TracksEventPayload);
}

// =============================================================================
// Meters (non-standard envelope: { type, event, m } — NOT inside payload)
// =============================================================================

function meters(meterData: Record<string, Partial<MeterData>>): ServerMessage {
  const filled: Record<string, MeterData> = {};
  for (const [guid, data] of Object.entries(meterData)) {
    filled[guid] = {
      i: data.i ?? 0,
      l: data.l ?? 0,
      r: data.r ?? 0,
      c: data.c ?? false,
      ...data,
    } as MeterData;
  }
  // Meters use non-standard envelope: m at root, not in payload
  return { type: 'event', event: 'meters', m: filled } as unknown as ServerMessage;
}

// =============================================================================
// Markers
// =============================================================================

function wsMarker(overrides?: Partial<WSMarker>): WSMarker {
  return {
    id: 0,
    position: 0,
    positionBeats: 0,
    positionBars: '1.1.00',
    name: 'Marker 1',
    color: 0,
    ...overrides,
  };
}

function markers(markerList: Partial<WSMarker>[]): ServerMessage {
  return event('markers', {
    markers: markerList.map(m => wsMarker(m)),
  } satisfies MarkersEventPayload);
}

// =============================================================================
// Regions
// =============================================================================

function wsRegion(overrides?: Partial<WSRegion>): WSRegion {
  return {
    id: 0,
    start: 0,
    end: 10,
    startBeats: 0,
    endBeats: 20,
    startBars: '1.1.00',
    endBars: '5.1.00',
    lengthBars: '4.0.00',
    name: 'Region 1',
    color: 0,
    ...overrides,
  };
}

function regions(regionList: Partial<WSRegion>[]): ServerMessage {
  return event('regions', {
    regions: regionList.map(r => wsRegion(r)),
  } satisfies RegionsEventPayload);
}

// =============================================================================
// Items
// =============================================================================

function wsItem(overrides?: Partial<WSItem>): WSItem {
  return {
    guid: '{ITEM-GUID-0001}',
    trackIdx: 1,
    itemIdx: 0,
    position: 0,
    length: 10,
    color: 0,
    locked: false,
    selected: false,
    activeTakeIdx: 0,
    hasNotes: false,
    takeCount: 1,
    activeTakeName: 'Take 1',
    activeTakeGuid: '{TAKE-GUID-0001}',
    activeTakeIsMidi: false,
    activeTakeColor: null,
    ...overrides,
  };
}

function items(itemList: Partial<WSItem>[]): ServerMessage {
  return event('items', {
    items: itemList.map(i => wsItem(i)),
  } satisfies ItemsEventPayload);
}

// =============================================================================
// FX State (broadcast)
// =============================================================================

function wsFxSlot(overrides?: Partial<WSFxSlot>): WSFxSlot {
  return {
    trackIdx: 1,
    fxIndex: 0,
    name: 'ReaEQ',
    presetName: 'Default',
    presetIndex: 0,
    presetCount: 10,
    modified: false,
    enabled: true,
    ...overrides,
  };
}

function fxState(fxList: Partial<WSFxSlot>[]): ServerMessage {
  return event('fx_state', {
    fx: fxList.map(f => wsFxSlot(f)),
  } satisfies FxStateEventPayload);
}

// =============================================================================
// Sends State (broadcast)
// =============================================================================

function wsSendSlot(overrides?: Partial<WSSendSlot>): WSSendSlot {
  return {
    srcTrackIdx: 1,
    destTrackIdx: 2,
    sendIndex: 0,
    volume: 1.0,
    pan: 0,
    muted: false,
    mode: 0,
    ...overrides,
  };
}

function sendsState(sendList: Partial<WSSendSlot>[]): ServerMessage {
  return event('sends_state', {
    sends: sendList.map(s => wsSendSlot(s)),
  } satisfies SendsStateEventPayload);
}

// =============================================================================
// Routing State (per-client subscription)
// =============================================================================

function routingState(overrides?: Partial<RoutingStateEventPayload>): ServerMessage {
  return event('routing_state', {
    trackGuid: '{AAAA-BBBB-CCCC-DDDD}',
    sends: [],
    receives: [],
    hwOutputs: [],
    ...overrides,
  } satisfies RoutingStateEventPayload);
}

// =============================================================================
// Action Toggle State
// =============================================================================

function actionToggleState(changes: Partial<ToggleStateChange>[]): ServerMessage {
  return event('actionToggleState', {
    changes: changes.map(c => ({
      s: c.s ?? 0,
      c: c.c ?? 40012,
      v: c.v ?? 1,
    })),
  } satisfies ActionToggleStateEventPayload);
}

// =============================================================================
// Tempo Map
// =============================================================================

function wsTempoMarker(overrides?: Partial<WSTempoMarker>): WSTempoMarker {
  return {
    position: 0,
    positionBeats: 0,
    bpm: 120,
    timesigNum: 4,
    timesigDenom: 4,
    linear: false,
    ...overrides,
  };
}

function tempoMap(markerList: Partial<WSTempoMarker>[]): ServerMessage {
  return event('tempoMap', {
    markers: markerList.map(m => wsTempoMarker(m)),
  } satisfies TempoMapEventPayload);
}

// =============================================================================
// Project Notes Changed
// =============================================================================

function projectNotesChanged(hash: string): ServerMessage {
  return event('projectNotesChanged', {
    hash,
  } satisfies ProjectNotesChangedEventPayload);
}

// =============================================================================
// Playlist
// =============================================================================

function playlist(overrides?: Partial<PlaylistEventPayload>): ServerMessage {
  return event('playlist', {
    playlists: [],
    activePlaylistIndex: null,
    currentEntryIndex: null,
    loopsRemaining: null,
    currentLoopIteration: null,
    isPlaylistActive: false,
    isPaused: false,
    advanceAfterLoop: false,
    ...overrides,
  } satisfies PlaylistEventPayload);
}

// =============================================================================
// Peaks (tile-based)
// =============================================================================

function peaksTile(overrides?: Partial<PeaksTile>): PeaksTile {
  return {
    takeGuid: '{TAKE-GUID-0001}',
    epoch: 1234567890,
    lod: 5,
    tileIndex: 0,
    itemPosition: 0,
    startTime: 0,
    endTime: 4,
    channels: 2,
    peaks: [{ l: [-0.5, 0.5], r: [-0.4, 0.4] }],
    ...overrides,
  };
}

function peaks(tiles: Partial<PeaksTile>[]): ServerMessage {
  return event('peaks', {
    tiles: tiles.map(t => peaksTile(t)),
  } satisfies PeaksEventPayload);
}

// =============================================================================
// FX Chain (per-client subscription)
// =============================================================================

function wsFxChainSlot(overrides?: Partial<WSFxChainSlot>): WSFxChainSlot {
  return {
    fxGuid: '{FX-GUID-0001}',
    fxIndex: 0,
    name: 'ReaEQ',
    presetName: 'Default',
    presetIndex: 0,
    presetCount: 10,
    modified: false,
    enabled: true,
    ...overrides,
  };
}

function fxChain(trackGuid: string, fxList: Partial<WSFxChainSlot>[]): ServerMessage {
  return event('trackFxChain', {
    trackGuid,
    fx: fxList.map(f => wsFxChainSlot(f)),
  } satisfies FxChainEventPayload);
}

// =============================================================================
// FX Params (per-client subscription)
// =============================================================================

function fxParams(overrides?: Partial<FxParamsEventPayload>): ServerMessage {
  return event('trackFxParams', {
    trackGuid: '{AAAA-BBBB-CCCC-DDDD}',
    fxGuid: '{FX-GUID-0001}',
    paramCount: 3,
    nameHash: 12345,
    values: { '0': [0.5, '50%'], '1': [0.75, '75%'] },
    ...overrides,
  } satisfies FxParamsEventPayload);
}

function fxParamsError(error: string): ServerMessage {
  return event('trackFxParamsError', {
    error,
  } satisfies FxParamsErrorEventPayload);
}

// =============================================================================
// Tuner (per-client subscription)
// =============================================================================

function tuner(overrides?: Partial<TunerEventPayload>): ServerMessage {
  return event('tuner', {
    trackGuid: '{AAAA-BBBB-CCCC-DDDD}',
    freq: 440,
    note: 69,
    noteName: 'A',
    octave: 4,
    cents: 0,
    conf: 0.95,
    inTune: true,
    referenceHz: 440,
    thresholdDb: -60,
    ...overrides,
  } satisfies TunerEventPayload);
}

function tunerError(error: string): ServerMessage {
  return event('tunerError', {
    error,
  } satisfies TunerErrorEventPayload);
}

// =============================================================================
// Reload
// =============================================================================

function reload(): ServerMessage {
  return { type: 'event', event: 'reload' } as EventMessage;
}

// =============================================================================
// Clock Sync Response
// =============================================================================

function clockSyncResponse(overrides?: Partial<ClockSyncResponse>): ServerMessage {
  return {
    type: 'clockSyncResponse',
    t0: 1000,
    t1: 1005,
    t2: 1006,
    ...overrides,
  } satisfies ClockSyncResponse;
}

// =============================================================================
// Namespace export — use as: msg.transport({ playState: 1 })
// =============================================================================

export const msg = {
  transport,
  transportTick,
  project,
  trackSkeleton,
  skeletonTrack,
  tracks,
  wsTrack,
  meters,
  markers,
  wsMarker,
  regions,
  wsRegion,
  items,
  wsItem,
  fxState,
  wsFxSlot,
  sendsState,
  wsSendSlot,
  routingState,
  actionToggleState,
  tempoMap,
  wsTempoMarker,
  projectNotesChanged,
  playlist,
  peaks,
  peaksTile,
  fxChain,
  wsFxChainSlot,
  fxParams,
  fxParamsError,
  tuner,
  tunerError,
  reload,
  clockSyncResponse,
};
