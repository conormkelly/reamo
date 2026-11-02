import { describe, it, expect, beforeEach } from 'vitest';
import { loadSavedReferenceHz, loadSavedThresholdDb, savedSettingsToSend, tunerKind } from './tunerStorage';

describe('tuner settings saved on this phone', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('are null until the user has chosen them, so the tuner keeps its own defaults', () => {
    expect(loadSavedReferenceHz()).toBeNull();
    expect(loadSavedThresholdDb('track')).toBeNull();
    expect(loadSavedThresholdDb('master')).toBeNull();
    expect(savedSettingsToSend('master', { referenceHz: 440, thresholdDb: -90 })).toEqual([]);
    expect(savedSettingsToSend('track', { referenceHz: 440, thresholdDb: -90 })).toEqual([]);
  });

  it('are sent when they differ from what the tuner reports', () => {
    localStorage.setItem('tuner-reference', '442');
    localStorage.setItem('tuner-threshold-track', '-70');
    expect(savedSettingsToSend('track', { referenceHz: 440, thresholdDb: -90 })).toEqual([
      ['reference', 442],
      ['threshold', -70],
    ]);
    expect(savedSettingsToSend('track', { referenceHz: 442, thresholdDb: -70 })).toEqual([]);
  });

  it("never apply a threshold saved for a track tuner's JSFX to the analyser", () => {
    // `tuner-threshold` gated the JSFX's whole input; the analyser has its
    // own noise floor, and an old value would only hide quiet notes.
    localStorage.setItem('tuner-threshold', '-50');
    expect(loadSavedThresholdDb('track')).toBeNull();
    expect(loadSavedThresholdDb('master')).toBeNull();
    expect(savedSettingsToSend('track', { referenceHz: 440, thresholdDb: -90 })).toEqual([]);
  });

  it("keep the master's threshold apart from the tracks', and share A4", () => {
    localStorage.setItem('tuner-reference', '442');
    localStorage.setItem('tuner-threshold-track', '-60');
    expect(loadSavedThresholdDb('master')).toBeNull();
    expect(savedSettingsToSend('master', { referenceHz: 440, thresholdDb: -90 })).toEqual([['reference', 442]]);
    localStorage.setItem('tuner-threshold-master', '-80');
    expect(loadSavedThresholdDb('master')).toBe(-80);
    expect(loadSavedThresholdDb('track')).toBe(-60);
  });

  it('are ignored outside the ranges the settings offer', () => {
    localStorage.setItem('tuner-reference', '300');
    localStorage.setItem('tuner-threshold-track', '-20');
    expect(loadSavedReferenceHz()).toBeNull();
    expect(loadSavedThresholdDb('track')).toBeNull();
    localStorage.setItem('tuner-threshold-track', 'junk');
    expect(loadSavedThresholdDb('track')).toBeNull();
  });

  it('name the master by its GUID and every other GUID a track', () => {
    expect(tunerKind('master')).toBe('master');
    expect(tunerKind('{ABC}')).toBe('track');
  });
});
