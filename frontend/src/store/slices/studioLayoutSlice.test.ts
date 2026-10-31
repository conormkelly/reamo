/**
 * Tests for studioLayoutSlice — the header-menu layout preferences and their
 * localStorage round-trip.
 *
 * Key contracts:
 * - Every setter saves all four preferences
 * - loadLayoutFromStorage restores saved values
 * - Missing, non-boolean or unparseable stored values fall back to defaults
 *   instead of reaching components as truthy/falsy junk
 */

import { describe, it, expect, beforeEach, beforeAll } from 'vitest';
import { useReaperStore } from '../index';

const STORAGE_KEY = 'reamo_studio_layout';

const DEFAULTS = {
  showRecordingActions: true,
  pinMasterTrack: true,
  showAddTrackButton: true,
  showPianoWheels: true,
};

// Node 25+ has a broken native localStorage that shadows jsdom's.
// Provide a proper in-memory implementation for tests.
beforeAll(() => {
  const store = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => store.set(key, String(value)),
      removeItem: (key: string) => store.delete(key),
      clear: () => store.clear(),
      get length() { return store.size; },
      key: (i: number) => [...store.keys()][i] ?? null,
    },
    configurable: true,
    writable: true,
  });
});

function layoutPrefs() {
  const s = useReaperStore.getState();
  return {
    showRecordingActions: s.showRecordingActions,
    pinMasterTrack: s.pinMasterTrack,
    showAddTrackButton: s.showAddTrackButton,
    showPianoWheels: s.showPianoWheels,
  };
}

describe('studioLayoutSlice', () => {
  beforeEach(() => {
    localStorage.clear();
    useReaperStore.setState(DEFAULTS);
  });

  it('values saved by the setters are restored by loadLayoutFromStorage', () => {
    const s = useReaperStore.getState();
    s.setShowRecordingActions(false);
    s.setPinMasterTrack(false);
    s.setShowAddTrackButton(false);
    s.setShowPianoWheels(false);

    // Back to the defaults a fresh page load starts from
    useReaperStore.setState(DEFAULTS);
    useReaperStore.getState().loadLayoutFromStorage();

    expect(layoutPrefs()).toEqual({
      showRecordingActions: false,
      pinMasterTrack: false,
      showAddTrackButton: false,
      showPianoWheels: false,
    });
  });

  it('a preference missing from storage keeps its default', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ pinMasterTrack: false }));

    useReaperStore.getState().loadLayoutFromStorage();

    expect(layoutPrefs()).toEqual({ ...DEFAULTS, pinMasterTrack: false });
  });

  it('a non-boolean stored value falls back to the default instead of being used as-is', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      showRecordingActions: 'false',
      pinMasterTrack: 0,
      showAddTrackButton: null,
      showPianoWheels: false,
    }));

    useReaperStore.getState().loadLayoutFromStorage();

    expect(layoutPrefs()).toEqual({ ...DEFAULTS, showPianoWheels: false });
  });

  it.each([
    ['unparseable JSON', '{not json'],
    ['a JSON array', '[false, false]'],
    ['a JSON primitive', 'false'],
  ])('stored %s leaves every preference at its default', (_label, raw) => {
    localStorage.setItem(STORAGE_KEY, raw);

    useReaperStore.getState().loadLayoutFromStorage();

    expect(layoutPrefs()).toEqual(DEFAULTS);
  });

  it('nothing stored leaves every preference at its default', () => {
    useReaperStore.getState().loadLayoutFromStorage();

    expect(layoutPrefs()).toEqual(DEFAULTS);
  });
});
