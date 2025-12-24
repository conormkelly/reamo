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
};

// =============================================================================
// Track Commands
// =============================================================================

export const track = {
  setVolume: (trackIdx: number, volume: number): WSCommand => ({
    command: 'track/setVolume',
    params: { trackIdx, volume },
  }),
  setPan: (trackIdx: number, pan: number): WSCommand => ({
    command: 'track/setPan',
    params: { trackIdx, pan },
  }),
  setMute: (trackIdx: number, mute?: number): WSCommand => ({
    command: 'track/setMute',
    params: { trackIdx, mute },
  }),
  setSolo: (trackIdx: number, solo?: number): WSCommand => ({
    command: 'track/setSolo',
    params: { trackIdx, solo },
  }),
  setRecArm: (trackIdx: number, arm?: number): WSCommand => ({
    command: 'track/setRecArm',
    params: { trackIdx, arm },
  }),
  setRecMon: (trackIdx: number, mon?: number): WSCommand => ({
    command: 'track/setRecMon',
    params: { trackIdx, mon },
  }),
  setFxEnabled: (trackIdx: number, enabled?: number): WSCommand => ({
    command: 'track/setFxEnabled',
    params: { trackIdx, enabled },
  }),
  setSelected: (trackIdx: number, selected?: number): WSCommand => ({
    command: 'track/setSelected',
    params: { trackIdx, selected },
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
// Meter Commands
// =============================================================================

export const meter = {
  clearClip: (trackIdx: number): WSCommand => ({
    command: 'meter/clearClip',
    params: { trackIdx },
  }),
};

// =============================================================================
// Action Commands
// =============================================================================

export const action = {
  execute: (commandId: number): WSCommand => ({
    command: 'action/execute',
    params: { commandId },
  }),
  executeByName: (name: string): WSCommand => ({
    command: 'action/executeByName',
    params: { name },
  }),
  getToggleState: (commandId: number): WSCommand => ({
    command: 'action/getToggleState',
    params: { commandId },
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
