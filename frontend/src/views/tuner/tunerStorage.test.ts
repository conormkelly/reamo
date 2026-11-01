import { describe, it, expect, beforeEach } from 'vitest';
import { loadSavedReferenceHz, loadSavedThresholdDb, savedSettingsToSend } from './tunerStorage';

describe('tuner settings saved on this phone', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('are null until the user has chosen them, so the tuner keeps its own defaults', () => {
    expect(loadSavedReferenceHz()).toBeNull();
    expect(loadSavedThresholdDb()).toBeNull();
    // The analyser's -90 and the JSFX's -60 both stand: nothing is sent.
    expect(savedSettingsToSend({ referenceHz: 440, thresholdDb: -90 })).toEqual([]);
    expect(savedSettingsToSend({ referenceHz: 440, thresholdDb: -60 })).toEqual([]);
  });

  it('are sent when they differ from what the tuner reports', () => {
    localStorage.setItem('tuner-reference', '442');
    localStorage.setItem('tuner-threshold', '-70');
    expect(savedSettingsToSend({ referenceHz: 440, thresholdDb: -90 })).toEqual([
      ['reference', 442],
      ['threshold', -70],
    ]);
    expect(savedSettingsToSend({ referenceHz: 442, thresholdDb: -70 })).toEqual([]);
  });

  it('are ignored outside the ranges the settings offer', () => {
    localStorage.setItem('tuner-reference', '300');
    localStorage.setItem('tuner-threshold', '-20');
    expect(loadSavedReferenceHz()).toBeNull();
    expect(loadSavedThresholdDb()).toBeNull();
    localStorage.setItem('tuner-threshold', 'junk');
    expect(loadSavedThresholdDb()).toBeNull();
  });
});
