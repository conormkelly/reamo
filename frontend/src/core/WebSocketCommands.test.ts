/**
 * WebSocketCommands - addressing
 *
 * Commands that change a track, item or plugin name it by GUID when the
 * caller has one: indices shift when anything is added, removed or
 * reordered around the target, and the server then acts on the neighbour.
 */

import { describe, it, expect } from 'vitest';
import { track, trackFx, item } from './WebSocketCommands';

describe('track commands', () => {
  it('name the track by GUID when given one, and by index otherwise', () => {
    expect(track.delete(3, '{VOX}').params).toEqual({ trackGuid: '{VOX}' });
    expect(track.duplicate(3, '{VOX}').params).toEqual({ trackGuid: '{VOX}' });
    expect(track.rename(3, 'Lead', '{VOX}').params).toEqual({ trackGuid: '{VOX}', name: 'Lead' });
    expect(track.delete(3).params).toEqual({ trackIdx: 3 });
  });
});

describe('trackFx commands', () => {
  it('name the plugin by GUID when given one, so a reordered chain cannot redirect them', () => {
    expect(trackFx.presetNext(1, 2, '{T}', '{FX}').params).toEqual({ trackGuid: '{T}', fxGuid: '{FX}' });
    expect(trackFx.presetPrev(1, 2, '{T}', '{FX}').params).toEqual({ trackGuid: '{T}', fxGuid: '{FX}' });
    expect(trackFx.presetSet(1, 2, 5, '{T}', '{FX}').params).toEqual({ trackGuid: '{T}', fxGuid: '{FX}', presetIdx: 5 });
    expect(trackFx.setEnabled(1, 2, 0, '{T}', '{FX}').params).toEqual({ trackGuid: '{T}', fxGuid: '{FX}', enabled: 0 });
    expect(trackFx.presetNext(1, 2).params).toEqual({ trackIdx: 1, fxIdx: 2 });
  });
});

describe('item commands', () => {
  it('name the item by GUID', () => {
    expect(item.setNotes('{IT}', 'x').params).toEqual({ itemGuid: '{IT}', notes: 'x' });
    expect(item.getNotes('{IT}').params).toEqual({ itemGuid: '{IT}' });
    expect(item.setActiveTake('{IT}', 1).params).toEqual({ itemGuid: '{IT}', takeIdx: 1 });
    expect(item.setLock('{IT}', 1).params).toEqual({ itemGuid: '{IT}', locked: 1 });
    expect(item.setColor('{IT}', 255).params).toEqual({ itemGuid: '{IT}', color: 255 });
  });
});
