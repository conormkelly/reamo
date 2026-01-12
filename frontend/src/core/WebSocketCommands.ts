/**
 * WebSocket Command Helpers
 * Maps to extension/API.md command names
 */

// Command with optional params
export interface WSCommand {
  command: string;
  params?: Record<string, unknown>;
}

// =============================================================================
// Transport Commands
// =============================================================================

export const transport = {
  play: (): WSCommand => ({ command: 'transport/play' }),
  stop: (): WSCommand => ({ command: 'transport/stop' }),
  pause: (): WSCommand => ({ command: 'transport/pause' }),
  record: (): WSCommand => ({ command: 'transport/record' }),
  playPause: (): WSCommand => ({ command: 'transport/playPause' }),
  seek: (position: number): WSCommand => ({
    command: 'transport/seek',
    params: { position },
  }),
  seekBeats: (bar: number, beat?: number): WSCommand => ({
    command: 'transport/seekBeats',
    params: { bar, beat },
  }),
  goStart: (): WSCommand => ({ command: 'transport/goStart' }),
  goEnd: (): WSCommand => ({ command: 'transport/goEnd' }),
  stopAndDelete: (): WSCommand => ({ command: 'transport/stopAndDelete' }),
};

// =============================================================================
// Time Selection Commands
// =============================================================================

export const timeSelection = {
  set: (start: number, end: number): WSCommand => ({
    command: 'timeSelection/set',
    params: { start, end },
  }),
  setByBars: (
    startBar: number,
    endBar: number,
    startBeat?: number,
    endBeat?: number
  ): WSCommand => ({
    command: 'timeSelection/setByBars',
    params: { startBar, endBar, startBeat, endBeat },
  }),
  clear: (): WSCommand => ({ command: 'timeSelection/clear' }),
  goStart: (): WSCommand => ({ command: 'timeSelection/goStart' }),
  goEnd: (): WSCommand => ({ command: 'timeSelection/goEnd' }),
  setStartAtCursor: (): WSCommand => ({
    command: 'timeSelection/setStartAtCursor',
  }),
  setEndAtCursor: (): WSCommand => ({
    command: 'timeSelection/setEndAtCursor',
  }),
};

// =============================================================================
// Repeat Commands
// =============================================================================

export const repeat = {
  set: (enabled: number): WSCommand => ({
    command: 'repeat/set',
    params: { enabled },
  }),
  toggle: (): WSCommand => ({ command: 'repeat/toggle' }),
};

// =============================================================================
// Marker Commands
// =============================================================================

export const marker = {
  add: (position: number, name?: string, color?: number): WSCommand => ({
    command: 'marker/add',
    params: { position, name, color },
  }),
  update: (
    id: number,
    updates: { position?: number; name?: string; color?: number }
  ): WSCommand => ({
    command: 'marker/update',
    params: { id, ...updates },
  }),
  delete: (id: number): WSCommand => ({
    command: 'marker/delete',
    params: { id },
  }),
  goto: (id: number): WSCommand => ({
    command: 'marker/goto',
    params: { id },
  }),
  prev: (): WSCommand => ({ command: 'marker/prev' }),
  next: (): WSCommand => ({ command: 'marker/next' }),
};

// =============================================================================
// Region Commands
// =============================================================================

/** Single operation in a region batch */
export interface RegionBatchOp {
  op: 'update' | 'delete' | 'create';
  id?: number; // Required for update/delete
  start?: number;
  end?: number;
  name?: string;
  color?: number;
}

export const region = {
  add: (
    start: number,
    end: number,
    name?: string,
    color?: number
  ): WSCommand => ({
    command: 'region/add',
    params: { start, end, name, color },
  }),
  update: (
    id: number,
    updates: { start?: number; end?: number; name?: string; color?: number }
  ): WSCommand => ({
    command: 'region/update',
    params: { id, ...updates },
  }),
  delete: (id: number): WSCommand => ({
    command: 'region/delete',
    params: { id },
  }),
  goto: (id: number): WSCommand => ({
    command: 'region/goto',
    params: { id },
  }),
  /** Batch multiple region operations in a single undo block */
  batch: (ops: RegionBatchOp[]): WSCommand => ({
    command: 'region/batch',
    params: { ops },
  }),
};

// =============================================================================
// Track Commands
// =============================================================================

/** Subscription parameters for track/subscribe command */
export interface TrackSubscribeParams {
  range?: { start: number; end: number };
  guids?: string[];
  includeMaster?: boolean;
}

export const track = {
  /** Subscribe to track updates for a range or specific GUIDs.
   * Replaces any previous subscription. Tracks events + meters only poll subscribed tracks.
   * Use range mode for scrolling mixer, GUID mode for filtered views.
   */
  subscribe: (params: TrackSubscribeParams): WSCommand => ({
    command: 'track/subscribe',
    params: { ...params },
  }),
  /** Unsubscribe from track updates. Called automatically on disconnect. */
  unsubscribe: (): WSCommand => ({
    command: 'track/unsubscribe',
  }),
  setVolume: (trackIdx: number, volume: number, trackGuid?: string): WSCommand => ({
    command: 'track/setVolume',
    params: trackGuid ? { trackGuid, volume } : { trackIdx, volume },
  }),
  setPan: (trackIdx: number, pan: number, trackGuid?: string): WSCommand => ({
    command: 'track/setPan',
    params: trackGuid ? { trackGuid, pan } : { trackIdx, pan },
  }),
  setMute: (trackIdx: number, mute?: number, trackGuid?: string): WSCommand => ({
    command: 'track/setMute',
    params: trackGuid ? { trackGuid, mute } : { trackIdx, mute },
  }),
  setSolo: (trackIdx: number, solo?: number, trackGuid?: string): WSCommand => ({
    command: 'track/setSolo',
    params: trackGuid ? { trackGuid, solo } : { trackIdx, solo },
  }),
  setRecArm: (trackIdx: number, arm?: number, trackGuid?: string): WSCommand => ({
    command: 'track/setRecArm',
    params: trackGuid ? { trackGuid, arm } : { trackIdx, arm },
  }),
  setRecMon: (trackIdx: number, mon?: number, trackGuid?: string): WSCommand => ({
    command: 'track/setRecMon',
    params: trackGuid ? { trackGuid, mon } : { trackIdx, mon },
  }),
  setFxEnabled: (trackIdx: number, enabled?: number, trackGuid?: string): WSCommand => ({
    command: 'track/setFxEnabled',
    params: trackGuid ? { trackGuid, enabled } : { trackIdx, enabled },
  }),
  setSelected: (trackIdx: number, selected?: number, trackGuid?: string): WSCommand => ({
    command: 'track/setSelected',
    params: trackGuid ? { trackGuid, selected } : { trackIdx, selected },
  }),
  unselectAll: (): WSCommand => ({
    command: 'track/unselectAll',
  }),
  /** Get full FX chain details for a track (on-demand) with optional pagination */
  getFx: (trackIdx: number, offset?: number, limit?: number): WSCommand => ({
    command: 'track/getFx',
    params: { trackIdx, ...(offset !== undefined && { offset }), ...(limit !== undefined && { limit }) },
  }),
  /** Get full send routing details for a track (on-demand) with optional pagination */
  getSends: (trackIdx: number, offset?: number, limit?: number): WSCommand => ({
    command: 'track/getSends',
    params: { trackIdx, ...(offset !== undefined && { offset }), ...(limit !== undefined && { limit }) },
  }),
  /** Rename a track */
  rename: (trackIdx: number, name: string): WSCommand => ({
    command: 'track/rename',
    params: { trackIdx, name },
  }),
  /** Duplicate a track (includes FX, items, routing). Returns new track index. */
  duplicate: (trackIdx: number): WSCommand => ({
    command: 'track/duplicate',
    params: { trackIdx },
  }),
  /** Delete a track */
  delete: (trackIdx: number): WSCommand => ({
    command: 'track/delete',
    params: { trackIdx },
  }),
  /** Create a new track */
  create: (name?: string, afterTrackIdx?: number): WSCommand => ({
    command: 'track/create',
    params: { ...(name && { name }), ...(afterTrackIdx !== undefined && { afterTrackIdx }) },
  }),
};

// =============================================================================
// Item Commands
// =============================================================================

export const item = {
  setActiveTake: (
    trackIdx: number,
    itemIdx: number,
    takeIdx: number
  ): WSCommand => ({
    command: 'item/setActiveTake',
    params: { trackIdx, itemIdx, takeIdx },
  }),
  move: (trackIdx: number, itemIdx: number, position: number): WSCommand => ({
    command: 'item/move',
    params: { trackIdx, itemIdx, position },
  }),
  setColor: (trackIdx: number, itemIdx: number, color: number): WSCommand => ({
    command: 'item/setColor',
    params: { trackIdx, itemIdx, color },
  }),
  setLock: (
    trackIdx: number,
    itemIdx: number,
    locked?: number
  ): WSCommand => ({
    command: 'item/setLock',
    params: { trackIdx, itemIdx, locked },
  }),
  setNotes: (
    trackIdx: number,
    itemIdx: number,
    notes: string
  ): WSCommand => ({
    command: 'item/setNotes',
    params: { trackIdx, itemIdx, notes },
  }),
  delete: (trackIdx: number, itemIdx: number): WSCommand => ({
    command: 'item/delete',
    params: { trackIdx, itemIdx },
  }),
  goto: (trackIdx: number, itemIdx: number): WSCommand => ({
    command: 'item/goto',
    params: { trackIdx, itemIdx },
  }),
  select: (trackIdx: number, itemIdx: number): WSCommand => ({
    command: 'item/select',
    params: { trackIdx, itemIdx },
  }),
  selectInTimeSel: (): WSCommand => ({ command: 'item/selectInTimeSel' }),
  unselectAll: (): WSCommand => ({ command: 'item/unselectAll' }),
  /** Get waveform peak data for an item's active take */
  getPeaks: (
    trackIdx: number,
    itemIdx: number,
    width?: number
  ): WSCommand => ({
    command: 'item/getPeaks',
    params: { trackIdx, itemIdx, width },
  }),
  /** Get notes content for an item (on-demand) */
  getNotes: (trackIdx: number, itemIdx: number): WSCommand => ({
    command: 'item/getNotes',
    params: { trackIdx, itemIdx },
  }),
  /** Get full take list for an item (on-demand) */
  getTakes: (trackIdx: number, itemIdx: number): WSCommand => ({
    command: 'item/getTakes',
    params: { trackIdx, itemIdx },
  }),
};

// =============================================================================
// Take Commands
// =============================================================================

export const take = {
  next: (): WSCommand => ({ command: 'take/next' }),
  prev: (): WSCommand => ({ command: 'take/prev' }),
  delete: (): WSCommand => ({ command: 'take/delete' }),
  cropToActive: (): WSCommand => ({ command: 'take/cropToActive' }),
};

// =============================================================================
// Tempo Commands
// =============================================================================

export const tempo = {
  set: (bpm: number): WSCommand => ({
    command: 'tempo/set',
    params: { bpm },
  }),
  tap: (): WSCommand => ({ command: 'tempo/tap' }),
  /** Snap time to beat grid (tempo-aware) */
  snap: (time: number, subdivision = 1): WSCommand => ({
    command: 'tempo/snap',
    params: { time, subdivision },
  }),
  /** Get bar duration at a specific position */
  getBarDuration: (time: number): WSCommand => ({
    command: 'tempo/getBarDuration',
    params: { time },
  }),
  /** Convert time to beats with bar string */
  timeToBeats: (time: number): WSCommand => ({
    command: 'tempo/timeToBeats',
    params: { time },
  }),
  /** Convert bar.beat.ticks to time in seconds (tempo-aware) */
  barsToTime: (bar: number, beat = 1, ticks = 0): WSCommand => ({
    command: 'tempo/barsToTime',
    params: { bar, beat, ticks },
  }),
};

// =============================================================================
// Time Signature Commands
// =============================================================================

export const timesig = {
  set: (numerator: number, denominator: number): WSCommand => ({
    command: 'timesig/set',
    params: { numerator, denominator },
  }),
};

// =============================================================================
// Metronome Commands
// =============================================================================

export const metronome = {
  toggle: (): WSCommand => ({ command: 'metronome/toggle' }),
  getVolume: (): WSCommand => ({ command: 'metronome/getVolume' }),
  setVolume: (volumeDb?: number, volume?: number): WSCommand => ({
    command: 'metronome/setVolume',
    params: volumeDb !== undefined ? { volumeDb } : { volume },
  }),
};

// =============================================================================
// Master Track Commands
// =============================================================================

export const master = {
  /** Toggle master track mono/stereo mode */
  toggleMono: (): WSCommand => ({ command: 'master/toggleMono' }),
};

// =============================================================================
// Meter Commands
// =============================================================================

export const meter = {
  /** Clear clip indicator for a track. Use trackGuid for stability. */
  clearClip: (trackIdx: number, trackGuid?: string): WSCommand => ({
    command: 'meter/clearClip',
    params: trackGuid ? { trackGuid } : { trackIdx },
  }),
  // Note: meter/subscribe and meter/unsubscribe are obsolete.
  // Metering now follows track subscriptions automatically via track/subscribe.
};

// =============================================================================
// Action Commands
// =============================================================================

export const action = {
  /**
   * Execute a REAPER action by numeric command ID.
   * Use this for native REAPER actions (stable IDs).
   * @param commandId - The numeric command ID
   * @param sectionId - Optional section ID (default: 0 = main section)
   */
  execute: (commandId: number, sectionId?: number): WSCommand => ({
    command: 'action/execute',
    params: {
      commandId,
      ...(sectionId !== undefined && sectionId !== 0 && { sectionId }),
    },
  }),
  /**
   * Execute a REAPER action by named command string.
   * Use this for SWS/ReaPack/script actions (numeric IDs are unstable).
   * @param name - The named command (e.g., "_SWS_SAVESEL")
   * @param sectionId - Optional section ID (default: 0 = main section)
   */
  executeByName: (name: string, sectionId?: number): WSCommand => ({
    command: 'action/executeByName',
    params: {
      name,
      ...(sectionId !== undefined && sectionId !== 0 && { sectionId }),
    },
  }),
  /** Get toggle state of an action */
  getToggleState: (commandId: number): WSCommand => ({
    command: 'action/getToggleState',
    params: { commandId },
  }),
  /**
   * Get all available actions across all sections.
   * Returns: [[cmdId, sectionId, name, isToggle, namedId], ...]
   * namedId is the stable string identifier for SWS/scripts, null for native actions.
   */
  getActions: (): WSCommand => ({
    command: 'action/getActions',
    params: {},
  }),
};

// =============================================================================
// Action Toggle State Subscription Commands
// =============================================================================

/** Section-aware action reference for toggle state subscription */
export interface ActionRef {
  c: number; // commandId
  s: number; // sectionId (0 = Main, 32060 = MIDI Editor, etc.)
}

/** Section-aware named action reference for toggle state subscription */
export interface NamedActionRef {
  n: string; // named command (e.g., "_SWS_SAVESEL")
  s: number; // sectionId
}

export const actionToggleState = {
  /**
   * Subscribe to toggle state changes for actions.
   * Section-aware format:
   *   - actions: Array of {c: commandId, s: sectionId} for numeric commands
   *   - namedActions: Array of {n: name, s: sectionId} for SWS/scripts
   * Returns current state as array of {s, c, v} entries.
   * State values: -1 = not a toggle, 0 = off, 1 = on
   */
  subscribe: (params: {
    actions?: ActionRef[];
    namedActions?: NamedActionRef[];
  }): WSCommand => ({
    command: 'actionToggleState/subscribe',
    params: {
      ...(params.actions && params.actions.length > 0 && { actions: params.actions }),
      ...(params.namedActions && params.namedActions.length > 0 && { namedActions: params.namedActions }),
    },
  }),
  /** Unsubscribe from toggle state changes for actions. */
  unsubscribe: (params: {
    actions?: ActionRef[];
    namedActions?: NamedActionRef[];
  }): WSCommand => ({
    command: 'actionToggleState/unsubscribe',
    params: {
      ...(params.actions && params.actions.length > 0 && { actions: params.actions }),
      ...(params.namedActions && params.namedActions.length > 0 && { namedActions: params.namedActions }),
    },
  }),
};

// =============================================================================
// Undo Commands
// =============================================================================

export const undo = {
  add: (description: string): WSCommand => ({
    command: 'undo/add',
    params: { description },
  }),
  begin: (): WSCommand => ({ command: 'undo/begin' }),
  end: (description: string): WSCommand => ({
    command: 'undo/end',
    params: { description },
  }),
  /** Perform undo - returns { success: true, action: "description" } */
  do: (): WSCommand => ({ command: 'undo/do' }),
};

// =============================================================================
// Redo Commands
// =============================================================================

export const redo = {
  /** Perform redo - returns { success: true, action: "description" } */
  do: (): WSCommand => ({ command: 'redo/do' }),
};

// =============================================================================
// ExtState Commands
// =============================================================================

export const extstate = {
  get: (section: string, key: string): WSCommand => ({
    command: 'extstate/get',
    params: { section, key },
  }),
  set: (
    section: string,
    key: string,
    value: string,
    persist?: number
  ): WSCommand => ({
    command: 'extstate/set',
    params: { section, key, value, persist },
  }),
  projGet: (extname: string, key: string): WSCommand => ({
    command: 'extstate/projGet',
    params: { extname, key },
  }),
  projSet: (extname: string, key: string, value: string): WSCommand => ({
    command: 'extstate/projSet',
    params: { extname, key, value },
  }),
};

// =============================================================================
// Gesture Commands (for undo coalescing of continuous controls)
// =============================================================================

export type GestureControlType = 'volume' | 'pan' | 'send';

export const gesture = {
  /** Call when starting to drag a fader/knob. Use trackGuid for stability during gestures. */
  start: (controlType: GestureControlType, trackIdx: number, trackGuid?: string, sendIdx?: number): WSCommand => ({
    command: 'gesture/start',
    params: {
      controlType,
      ...(trackGuid ? { trackGuid } : { trackIdx }),
      ...(sendIdx !== undefined && { sendIdx }),
    },
  }),
  /** Call when releasing a fader/knob - triggers undo point creation. Use trackGuid for stability. */
  end: (controlType: GestureControlType, trackIdx: number, trackGuid?: string, sendIdx?: number): WSCommand => ({
    command: 'gesture/end',
    params: {
      controlType,
      ...(trackGuid ? { trackGuid } : { trackIdx }),
      ...(sendIdx !== undefined && { sendIdx }),
    },
  }),
};

// =============================================================================
// MIDI Commands (dual-sends to VKB + Control paths for learn & control)
// =============================================================================

export const midi = {
  /** Send MIDI Control Change message */
  cc: (cc: number, value: number, channel = 0): WSCommand => ({
    command: 'midi/cc',
    params: { cc, value, channel },
  }),
  /** Send MIDI Program Change message */
  pc: (program: number, channel = 0): WSCommand => ({
    command: 'midi/pc',
    params: { program, channel },
  }),
};

// =============================================================================
// Send Commands
// =============================================================================

export const send = {
  /** Set the volume level for a track send */
  setVolume: (trackIdx: number, sendIdx: number, volume: number): WSCommand => ({
    command: 'send/setVolume',
    params: { trackIdx, sendIdx, volume },
  }),
  /** Set the mute state for a track send */
  setMute: (trackIdx: number, sendIdx: number, muted: number): WSCommand => ({
    command: 'send/setMute',
    params: { trackIdx, sendIdx, muted },
  }),
};

// =============================================================================
// FX Commands
// =============================================================================

export const fx = {
  /** Navigate to the next preset for a track FX */
  presetNext: (trackIdx: number, fxIdx: number): WSCommand => ({
    command: 'fx/presetNext',
    params: { trackIdx, fxIdx },
  }),
  /** Navigate to the previous preset for a track FX */
  presetPrev: (trackIdx: number, fxIdx: number): WSCommand => ({
    command: 'fx/presetPrev',
    params: { trackIdx, fxIdx },
  }),
  /** Jump to a specific preset by index (-1 = default user, -2 = factory, 0+ = preset index) */
  presetSet: (trackIdx: number, fxIdx: number, presetIdx: number): WSCommand => ({
    command: 'fx/presetSet',
    params: { trackIdx, fxIdx, presetIdx },
  }),
};

// =============================================================================
// Project Notes Commands
// =============================================================================

export const projectNotes = {
  /** Subscribe to project notes updates.
   * Returns current notes and hash in the response.
   */
  subscribe: (): WSCommand => ({
    command: 'projectNotes/subscribe',
  }),
  /** Unsubscribe from project notes updates. */
  unsubscribe: (): WSCommand => ({
    command: 'projectNotes/unsubscribe',
  }),
  /** Get current project notes without subscribing. */
  get: (): WSCommand => ({
    command: 'projectNotes/get',
  }),
  /** Set project notes. Returns the saved notes and new hash. */
  set: (notes: string): WSCommand => ({
    command: 'projectNotes/set',
    params: { notes },
  }),
};

// =============================================================================
// Playlist Commands
// =============================================================================

export const playlist = {
  /** Create a new playlist. Returns { playlistIdx } */
  create: (name: string): WSCommand => ({
    command: 'playlist/create',
    params: { name },
  }),
  /** Delete a playlist. Stops playback if the deleted playlist is active. */
  delete: (playlistIdx: number): WSCommand => ({
    command: 'playlist/delete',
    params: { playlistIdx },
  }),
  /** Rename a playlist. */
  rename: (playlistIdx: number, name: string): WSCommand => ({
    command: 'playlist/rename',
    params: { playlistIdx, name },
  }),
  /** Add a region to a playlist. Returns { entryIdx } */
  addEntry: (
    playlistIdx: number,
    regionId: number,
    loopCount: number,
    atIdx?: number
  ): WSCommand => ({
    command: 'playlist/addEntry',
    params: { playlistIdx, regionId, loopCount, ...(atIdx !== undefined && { atIdx }) },
  }),
  /** Remove an entry from a playlist. */
  removeEntry: (playlistIdx: number, entryIdx: number): WSCommand => ({
    command: 'playlist/removeEntry',
    params: { playlistIdx, entryIdx },
  }),
  /** Change an entry's loop count. -1=infinite, 0=skip, 1+=times to play */
  setLoopCount: (
    playlistIdx: number,
    entryIdx: number,
    loopCount: number
  ): WSCommand => ({
    command: 'playlist/setLoopCount',
    params: { playlistIdx, entryIdx, loopCount },
  }),
  /** Move an entry to a new position within the playlist. */
  reorderEntry: (
    playlistIdx: number,
    fromIdx: number,
    toIdx: number
  ): WSCommand => ({
    command: 'playlist/reorderEntry',
    params: { playlistIdx, fromIdx, toIdx },
  }),
  /** Start playlist playback from entry 0, or resume if paused. */
  play: (playlistIdx: number): WSCommand => ({
    command: 'playlist/play',
    params: { playlistIdx },
  }),
  /** Start playlist playback from a specific entry. */
  playFromEntry: (playlistIdx: number, entryIdx: number): WSCommand => ({
    command: 'playlist/playFromEntry',
    params: { playlistIdx, entryIdx },
  }),
  /** Pause playlist playback. Remembers current position for resume. */
  pause: (): WSCommand => ({ command: 'playlist/pause' }),
  /** Stop playlist playback and exit playlist mode entirely. */
  stop: (): WSCommand => ({ command: 'playlist/stop' }),
  /** Advance to the next entry immediately. */
  next: (): WSCommand => ({ command: 'playlist/next' }),
  /** Go to the previous entry. */
  prev: (): WSCommand => ({ command: 'playlist/prev' }),
  /** Set flag to advance to next entry after the current loop completes. */
  advanceAfterLoop: (): WSCommand => ({ command: 'playlist/advanceAfterLoop' }),
  /** Set whether transport stops after the final region's last loop completes. */
  setStopAfterLast: (playlistIdx: number, stopAfterLast: boolean): WSCommand => ({
    command: 'playlist/setStopAfterLast',
    params: { playlistIdx, stopAfterLast: stopAfterLast ? 1 : 0 },
  }),
};
