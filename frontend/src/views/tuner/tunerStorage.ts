/**
 * Tuner settings this phone has saved: only what the user chose.
 *
 * The defaults belong to the tuner in REAPER, which reports its settings in
 * every event: the master's analyser starts at -90 dB (its learned noise
 * floor does the gating), a track's PitchDetect JSFX at -60 dB. Sending a
 * default from here would override whichever tuner is open, so an unsaved
 * setting is null and nothing is sent for it.
 */

const REFERENCE_KEY = 'tuner-reference';
const THRESHOLD_KEY = 'tuner-threshold';

/** The tuner's A4 range. */
const REFERENCE_MIN = 400;
const REFERENCE_MAX = 480;
/** The silence threshold's range, as TunerSettings offers it. */
const THRESHOLD_MIN = -90;
const THRESHOLD_MAX = -30;

function loadSaved(key: string, min: number, max: number, parse: (s: string) => number): number | null {
  try {
    const saved = localStorage.getItem(key);
    if (saved) {
      const value = parse(saved);
      if (!isNaN(value) && value >= min && value <= max) return value;
    }
  } catch {
    // Storage unavailable: nothing saved
  }
  return null;
}

/** The A4 reference the user saved, or null. */
export function loadSavedReferenceHz(): number | null {
  return loadSaved(REFERENCE_KEY, REFERENCE_MIN, REFERENCE_MAX, parseFloat);
}

/** The silence threshold the user saved, or null. */
export function loadSavedThresholdDb(): number | null {
  return loadSaved(THRESHOLD_KEY, THRESHOLD_MIN, THRESHOLD_MAX, (s) => parseInt(s, 10));
}

/** The saved settings that differ from what the tuner reports, as tuner/setParam params. */
export function savedSettingsToSend(current: {
  referenceHz: number;
  thresholdDb: number;
}): Array<['reference' | 'threshold', number]> {
  const out: Array<['reference' | 'threshold', number]> = [];
  const ref = loadSavedReferenceHz();
  if (ref !== null && ref !== current.referenceHz) out.push(['reference', ref]);
  const threshold = loadSavedThresholdDb();
  if (threshold !== null && threshold !== current.thresholdDb) out.push(['threshold', threshold]);
  return out;
}
