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
  guids?: readonly string[];
  /** Extra GUIDs to subscribe to alongside range or guids (e.g., info-selected track outside visible bank) */
  extraGuids?: readonly string[];
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
  /** Exclusive solo: unsolo all tracks, then solo this one. Single undo point. */
  setSoloExclusive: (trackIdx: number, trackGuid?: string): WSCommand => ({
    command: 'track/setSoloExclusive',
    params: trackGuid ? { trackGuid } : { trackIdx },
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
  /** Get hardware outputs for a track (on-demand) */
  getHwOutputs: (trackIdx: number): WSCommand => ({
    command: 'track/getHwOutputs',
    params: { trackIdx },
  }),
  /** Rename a track */
  rename: (trackIdx: number, name: string): WSCommand => ({
    command: 'track/rename',
    params: { trackIdx, name },
  }),
  /** Set track color. Pass 0 to reset to theme default. */
  setColor: (trackIdx: number, color: number, trackGuid?: string): WSCommand => ({
    command: 'track/setColor',
    params: trackGuid ? { trackGuid, color } : { trackIdx, color },
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
  /** Get current input configuration for a track (on-demand) */
  getInput: (trackIdx: number, trackGuid?: string): WSCommand => ({
    command: 'track/getInput',
    params: trackGuid ? { trackGuid } : { trackIdx },
  }),
  /** Set input configuration for a track. Use logical mode (recommended) or raw mode. */
  setInput: (params: {
    trackIdx?: number;
    trackGuid?: string;
    // Logical mode
    inputType?: 'none' | 'audio' | 'midi';
    channel?: number; // Audio: channel index; MIDI: channel 0=all, 1-16=specific
    stereo?: boolean; // Audio only: use stereo pair
    device?: number; // MIDI only: device index (62=VKB, 63=all)
    // Raw mode (bypass encoding)
    raw?: number;
  }): WSCommand => ({
    command: 'track/setInput',
    params,
  }),
};

// =============================================================================
// Input Commands
// =============================================================================

export const input = {
  /** Get list of available audio input channels */
  enumerateAudio: (): WSCommand => ({
    command: 'input/enumerateAudio',
  }),
  /** Get list of available MIDI input devices */
  enumerateMidi: (): WSCommand => ({
    command: 'input/enumerateMidi',
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
  /** Set active take by GUIDs (stable across track reordering) */
  setActiveTakeByGuid: (
    trackGuid: string,
    itemGuid: string,
    takeIdx: number
  ): WSCommand => ({
    command: 'item/setActiveTakeByGuid',
    params: { trackGuid, itemGuid, takeIdx },
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
  /** Toggle selection of a single item (does NOT affect other items) */
  toggleSelect: (guid: string): WSCommand => ({
    command: 'item/toggleSelect',
    params: { guid },
  }),
  /** Select next item on track (by position order) */
  selectNext: (
    trackIdx: number,
    itemIdx: number,
    wrap?: boolean
  ): WSCommand => ({
    command: 'item/selectNext',
    params: { trackIdx, itemIdx, ...(wrap !== undefined && { wrap: wrap ? 1 : 0 }) },
  }),
  /** Select previous item on track (by position order) */
  selectPrev: (
    trackIdx: number,
    itemIdx: number,
    wrap?: boolean
  ): WSCommand => ({
    command: 'item/selectPrev',
    params: { trackIdx, itemIdx, ...(wrap !== undefined && { wrap: wrap ? 1 : 0 }) },
  }),
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
  /** Set color for a specific take. Pass 0 to reset to theme default. */
  setColor: (trackIdx: number, itemIdx: number, takeIdx: number, color: number): WSCommand => ({
    command: 'take/setColor',
    params: { trackIdx, itemIdx, takeIdx, color },
  }),
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
// Count-In Commands
// =============================================================================

export const countIn = {
  togglePlayback: (): WSCommand => ({ command: 'countIn/togglePlayback' }),
  toggleRecord: (): WSCommand => ({ command: 'countIn/toggleRecord' }),
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
  // NOTE: undo/begin and undo/end commands removed - they're dangerous with multiple clients
  // as REAPER doesn't support nested undo blocks. Use gesture-based undo coalescing instead.
  // See research/REAPER_UNDO_BLOCKS.md for details.
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

export type GestureControlType = 'volume' | 'pan' | 'send' | 'sendPan' | 'receive' | 'receivePan' | 'hwOutputVolume' | 'hwOutputPan';

export const gesture = {
  /** Call when starting to drag a fader/knob. Use trackGuid for stability during gestures. */
  start: (controlType: GestureControlType, trackIdx: number, trackGuid?: string, sendIdx?: number, hwIdx?: number, recvIdx?: number): WSCommand => ({
    command: 'gesture/start',
    params: {
      controlType,
      ...(trackGuid ? { trackGuid } : { trackIdx }),
      ...(sendIdx !== undefined && { sendIdx }),
      ...(hwIdx !== undefined && { hwIdx }),
      ...(recvIdx !== undefined && { recvIdx }),
    },
  }),
  /** Call when releasing a fader/knob - triggers undo point creation. Use trackGuid for stability. */
  end: (controlType: GestureControlType, trackIdx: number, trackGuid?: string, sendIdx?: number, hwIdx?: number, recvIdx?: number): WSCommand => ({
    command: 'gesture/end',
    params: {
      controlType,
      ...(trackGuid ? { trackGuid } : { trackIdx }),
      ...(sendIdx !== undefined && { sendIdx }),
      ...(hwIdx !== undefined && { hwIdx }),
      ...(recvIdx !== undefined && { recvIdx }),
    },
  }),

  // FX Parameter gestures have different signature
  /** Start drag for FX parameter */
  startFxParam: (trackGuid: string, fxGuid: string, paramIdx: number): WSCommand => ({
    command: 'gesture/start',
    params: { controlType: 'fxParam', trackGuid, fxGuid, paramIdx },
  }),
  /** End drag for FX parameter - triggers undo point creation */
  endFxParam: (trackGuid: string, fxGuid: string, paramIdx: number): WSCommand => ({
    command: 'gesture/end',
    params: { controlType: 'fxParam', trackGuid, fxGuid, paramIdx },
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
  /** Send MIDI Note On message (use velocity=0 for note off) */
  noteOn: (note: number, velocity: number, channel = 0): WSCommand => ({
    command: 'midi/noteOn',
    params: { note, velocity, channel },
  }),
  /** Send MIDI Pitch Bend message (0-16383, center=8192) */
  pitchBend: (value: number, channel = 0): WSCommand => ({
    command: 'midi/pitchBend',
    params: { value, channel },
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
  /** Set the pan for a track send (-1.0 to 1.0) */
  setPan: (trackIdx: number, sendIdx: number, pan: number): WSCommand => ({
    command: 'send/setPan',
    params: { trackIdx, sendIdx, pan },
  }),
  /** Set the mode for a track send (0=post-fader, 1=pre-FX, 3=post-FX) */
  setMode: (trackIdx: number, sendIdx: number, mode: number): WSCommand => ({
    command: 'send/setMode',
    params: { trackIdx, sendIdx, mode },
  }),
  /** Create a new send from source track to destination track */
  add: (trackGuid: string, destTrackGuid: string): WSCommand => ({
    command: 'send/add',
    params: { trackGuid, destTrackGuid },
  }),
  /** Remove a send by index */
  remove: (trackGuid: string, sendIdx: number): WSCommand => ({
    command: 'send/remove',
    params: { trackGuid, sendIdx },
  }),
};

// =============================================================================
// Receive Commands
// =============================================================================

export const receive = {
  /** Set the volume level for a track receive */
  setVolume: (trackIdx: number, recvIdx: number, volume: number): WSCommand => ({
    command: 'receive/setVolume',
    params: { trackIdx, recvIdx, volume },
  }),
  /** Set the mute state for a track receive */
  setMute: (trackIdx: number, recvIdx: number, muted: number): WSCommand => ({
    command: 'receive/setMute',
    params: { trackIdx, recvIdx, muted },
  }),
  /** Set the pan for a track receive (-1.0 to 1.0) */
  setPan: (trackIdx: number, recvIdx: number, pan: number): WSCommand => ({
    command: 'receive/setPan',
    params: { trackIdx, recvIdx, pan },
  }),
  /** Set the mode for a track receive (0=post-fader, 1=pre-FX, 3=post-FX) */
  setMode: (trackIdx: number, recvIdx: number, mode: number): WSCommand => ({
    command: 'receive/setMode',
    params: { trackIdx, recvIdx, mode },
  }),
  /** Create a new receive on this track from another track */
  add: (trackGuid: string, srcTrackGuid: string): WSCommand => ({
    command: 'receive/add',
    params: { trackGuid, srcTrackGuid },
  }),
  /** Remove a receive by index */
  remove: (trackGuid: string, recvIdx: number): WSCommand => ({
    command: 'receive/remove',
    params: { trackGuid, recvIdx },
  }),
};

// =============================================================================
// Hardware Output Commands
// =============================================================================

export const hw = {
  /** Set the volume level for a hardware output */
  setVolume: (trackIdx: number, hwIdx: number, volume: number): WSCommand => ({
    command: 'hw/setVolume',
    params: { trackIdx, hwIdx, volume },
  }),
  /** Set the mute state for a hardware output */
  setMute: (trackIdx: number, hwIdx: number, muted: number): WSCommand => ({
    command: 'hw/setMute',
    params: { trackIdx, hwIdx, muted },
  }),
  /** Set the pan for a hardware output (-1.0 to 1.0) */
  setPan: (trackIdx: number, hwIdx: number, pan: number): WSCommand => ({
    command: 'hw/setPan',
    params: { trackIdx, hwIdx, pan },
  }),
  /** Set the mode for a hardware output (0=post-fader, 1=pre-FX, 3=post-FX) */
  setMode: (trackIdx: number, hwIdx: number, mode: number): WSCommand => ({
    command: 'hw/setMode',
    params: { trackIdx, hwIdx, mode },
  }),
  /** Create a new hardware output on this track */
  add: (trackGuid: string): WSCommand => ({
    command: 'hw/add',
    params: { trackGuid },
  }),
  /** Remove a hardware output by index */
  remove: (trackGuid: string, hwIdx: number): WSCommand => ({
    command: 'hw/remove',
    params: { trackGuid, hwIdx },
  }),
  /** Set the destination channel for a hardware output */
  setDestChannel: (trackIdx: number, hwIdx: number, destChannel: number): WSCommand => ({
    command: 'hw/setDestChannel',
    params: { trackIdx, hwIdx, destChannel },
  }),
  /** List available audio output channels */
  listOutputs: (): WSCommand => ({
    command: 'hw/listOutputs',
    params: {},
  }),
};

// =============================================================================
// Track FX Commands
// Uses trackFx/ prefix to match REAPER's TrackFX_* API family
// =============================================================================

export const trackFx = {
  /** Navigate to the next preset for a track FX */
  presetNext: (trackIdx: number, fxIdx: number): WSCommand => ({
    command: 'trackFx/presetNext',
    params: { trackIdx, fxIdx },
  }),
  /** Navigate to the previous preset for a track FX */
  presetPrev: (trackIdx: number, fxIdx: number): WSCommand => ({
    command: 'trackFx/presetPrev',
    params: { trackIdx, fxIdx },
  }),
  /** Jump to a specific preset by index (-1 = default user, -2 = factory, 0+ = preset index) */
  presetSet: (trackIdx: number, fxIdx: number, presetIdx: number): WSCommand => ({
    command: 'trackFx/presetSet',
    params: { trackIdx, fxIdx, presetIdx },
  }),
  /** Set FX enabled/bypassed state. Omit enabled to toggle. */
  setEnabled: (
    trackIdx: number,
    fxIdx: number,
    enabled?: number,
    trackGuid?: string
  ): WSCommand => ({
    command: 'trackFx/setEnabled',
    params: {
      ...(trackGuid ? { trackGuid } : { trackIdx }),
      fxIdx,
      ...(enabled !== undefined && { enabled }),
    },
  }),
  /** Add an FX to a track by name. Returns { fxGuid, fxIndex } */
  add: (trackGuid: string, fxName: string, position?: number): WSCommand => ({
    command: 'trackFx/add',
    params: { trackGuid, fxName, ...(position !== undefined && { position }) },
  }),
  /** Delete an FX from a track by GUID or index */
  delete: (trackGuid: string, fx: { fxGuid?: string; fxIndex?: number }): WSCommand => ({
    command: 'trackFx/delete',
    params: { trackGuid, ...fx },
  }),
  /** Move an FX to a new position. Returns { newIndex } */
  move: (trackGuid: string, fxGuid: string, toIndex: number): WSCommand => ({
    command: 'trackFx/move',
    params: { trackGuid, fxGuid, toIndex },
  }),
  /** Subscribe to FX chain updates for a track */
  subscribe: (trackGuid: string): WSCommand => ({
    command: 'trackFx/subscribe',
    params: { trackGuid },
  }),
  /** Unsubscribe from FX chain updates */
  unsubscribe: (): WSCommand => ({
    command: 'trackFx/unsubscribe',
  }),
};

/** @deprecated Use trackFx instead - fx/ commands renamed to trackFx/ */
export const fx = trackFx;

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

// =============================================================================
// Peaks Subscription Commands
// =============================================================================

/** Viewport parameters for adaptive peak resolution */
export interface PeaksViewport {
  /** Start time in seconds (project timeline position) */
  start: number;
  /** End time in seconds (project timeline position) */
  end: number;
  /** Viewport width in pixels (for peakrate calculation) */
  widthPx: number;
}

/** Subscription parameters for peaks/subscribe command */
export interface PeaksSubscribeParams {
  /** Range mode: subscribe to unified track indices [start, end] */
  range?: { start: number; end: number };
  /** GUID mode: subscribe to specific track GUIDs */
  guids?: string[];
  /** Number of peak samples per item (default 30, used as fallback) */
  sampleCount?: number;
  /** Viewport for adaptive resolution (Phase 2) */
  viewport?: PeaksViewport;
}

export const peaks = {
  /**
   * Subscribe to peaks for multiple tracks.
   * Supports two mutually exclusive modes:
   * - Range mode: subscribe to track indices [start, end] (for sequential bank navigation)
   * - GUID mode: subscribe to specific track GUIDs (for filtered/custom bank views)
   *
   * After subscribing, the client receives "peaks" events with data for all subscribed tracks.
   * Events are track-keyed maps for O(1) lookup: { tracks: { "1": { guid, items }, ... } }
   *
   * @param params.range - Track index range { start, end } (mutually exclusive with guids)
   * @param params.guids - Array of track GUIDs (mutually exclusive with range)
   * @param params.sampleCount - Number of peak samples per item (default 30, fallback)
   * @param params.viewport - Viewport for adaptive resolution (optional)
   */
  subscribe: (params: PeaksSubscribeParams): WSCommand => ({
    command: 'peaks/subscribe',
    params: {
      ...(params.range && { range: params.range }),
      ...(params.guids && { guids: params.guids }),
      ...(params.sampleCount !== undefined && { sampleCount: params.sampleCount }),
      ...(params.viewport && { viewport: params.viewport }),
    },
  }),
  /** Unsubscribe from peaks updates. */
  unsubscribe: (): WSCommand => ({
    command: 'peaks/unsubscribe',
  }),
  /**
   * Update viewport for adaptive peak resolution without re-subscribing.
   * Use this when panning/zooming to request peaks at appropriate resolution.
   * Requires an active subscription.
   */
  updateViewport: (viewport: PeaksViewport): WSCommand => ({
    command: 'peaks/updateViewport',
    params: { viewport },
  }),
};

// =============================================================================
// Routing Subscription Commands
// =============================================================================

export const routing = {
  /**
   * Subscribe to routing updates for a single track.
   * Provides real-time sends, receives, and hw outputs at 30Hz.
   * Only one track can be subscribed per client (for RoutingModal).
   *
   * @param trackGuid - GUID of the track to subscribe to
   */
  subscribe: (trackGuid: string): WSCommand => ({
    command: 'routing/subscribe',
    params: { trackGuid },
  }),
  /** Unsubscribe from routing updates. */
  unsubscribe: (): WSCommand => ({
    command: 'routing/unsubscribe',
  }),
};

// =============================================================================
// FX Plugin Commands (for Add FX browser)
// =============================================================================

export const fxPlugin = {
  /**
   * Get list of all installed FX plugins.
   * Returns: [["name", "ident"], ...] where ident is the identifier to pass to trackFx.add.
   * Large response (~1MB) - cache on frontend.
   */
  getList: (): WSCommand => ({
    command: 'fxPlugin/getList',
  }),
};

// =============================================================================
// FX Parameter Subscription Commands
// =============================================================================

// =============================================================================
// Tuner Subscription Commands
// =============================================================================

export const tuner = {
  /**
   * Subscribe to tuner on a track. Inserts JSFX if first subscriber.
   * Each client can only subscribe to one track at a time.
   *
   * @param trackGuid - GUID of the track to tune
   */
  subscribe: (trackGuid: string): WSCommand => ({
    command: 'tuner/subscribe',
    params: { trackGuid },
  }),

  /** Unsubscribe from tuner. Removes JSFX if last subscriber. */
  unsubscribe: (): WSCommand => ({
    command: 'tuner/unsubscribe',
  }),

  /**
   * Set tuner parameter (reference frequency or silence threshold).
   *
   * @param trackGuid - GUID of the track
   * @param param - "reference" (Hz, 400-480) or "threshold" (dB, -96 to 0)
   * @param value - Parameter value
   */
  setParam: (trackGuid: string, param: 'reference' | 'threshold', value: number): WSCommand => ({
    command: 'tuner/setParam',
    params: { trackGuid, param, value },
  }),
};

// =============================================================================
// FX Parameter Subscription Commands
// =============================================================================

export const trackFxParams = {
  /**
   * Get parameter skeleton (names) for an FX.
   * One-time fetch - frontend caches in LRU.
   * Returns: { params: ["Gain", "Frequency", "Q", ...] }
   */
  getParams: (trackGuid: string, fxGuid: string): WSCommand => ({
    command: 'trackFx/getParams',
    params: { trackGuid, fxGuid },
  }),
  /**
   * Subscribe to parameter values for an FX.
   * Supports range mode (for virtual scrolling) or indices mode (for filtered views).
   * Pushes updates at 30Hz for subscribed params only.
   */
  subscribe: (
    trackGuid: string,
    fxGuid: string,
    mode: { range: { start: number; end: number } } | { indices: number[] }
  ): WSCommand => ({
    command: 'trackFxParams/subscribe',
    params: { trackGuid, fxGuid, ...mode },
  }),
  /** Unsubscribe from parameter updates. */
  unsubscribe: (): WSCommand => ({
    command: 'trackFxParams/unsubscribe',
  }),
  /**
   * Set a parameter value.
   * Use with gesture/start and gesture/end for undo coalescing.
   */
  set: (trackGuid: string, fxGuid: string, paramIdx: number, value: number): WSCommand => ({
    command: 'trackFxParams/set',
    params: { trackGuid, fxGuid, paramIdx, value },
  }),
};
