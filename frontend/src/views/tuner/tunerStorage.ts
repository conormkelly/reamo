/**
 * Tuner settings this phone has saved: only what the user chose.
 *
 * The defaults belong to the tuner in REAPER, which reports its settings in
 * the subscribe response and every event: the master's analyser starts at
 * -90 dB (its learned noise floor does the gating), a track's PitchDetect
 * JSFX at -60 dB. Sending a default from here would override whichever
 * tuner is open, so an unsaved setting is null and nothing is sent for it.
 *
 * The threshold means different things to the two (a gate over the JSFX's
 * whole input, a floor under the analyser's own), so each kind of tuner
 * keeps its own: `tuner-threshold` for tracks, the key every earlier page
 * saved to when tracks were all it could tune, and `tuner-threshold-master`
 * for the master, which nothing earlier saved, so no old value, chosen or
 * not, reaches the analyser. A4 means the same to both and is shared.
 */

/** Which tuner a GUID opens. */
export type TunerKind = 'master' | 'track';

export function tunerKind(trackGuid: string): TunerKind {
  return trackGuid === 'master' ? 'master' : 'track';
}

const REFERENCE_KEY = 'tuner-reference';
const THRESHOLD_KEYS: Record<TunerKind, string> = {
  track: 'tuner-threshold',
  master: 'tuner-threshold-master',
};

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

function save(key: string, value: number): void {
  try {
    localStorage.setItem(key, String(value));
  } catch {
    // Ignore quota exceeded errors
  }
}

/** The A4 reference the user saved, or null. */
export function loadSavedReferenceHz(): number | null {
  return loadSaved(REFERENCE_KEY, REFERENCE_MIN, REFERENCE_MAX, parseFloat);
}

/** The silence threshold the user saved for this kind of tuner, or null. */
export function loadSavedThresholdDb(kind: TunerKind): number | null {
  return loadSaved(THRESHOLD_KEYS[kind], THRESHOLD_MIN, THRESHOLD_MAX, (s) => parseInt(s, 10));
}

export function saveReferenceHz(hz: number): void {
  save(REFERENCE_KEY, hz);
}

export function saveThresholdDb(kind: TunerKind, db: number): void {
  save(THRESHOLD_KEYS[kind], db);
}

/** The saved settings that differ from what the tuner reports, as tuner/setParam params. */
export function savedSettingsToSend(
  kind: TunerKind,
  current: { referenceHz: number; thresholdDb: number }
): Array<['reference' | 'threshold', number]> {
  const out: Array<['reference' | 'threshold', number]> = [];
  const ref = loadSavedReferenceHz();
  if (ref !== null && ref !== current.referenceHz) out.push(['reference', ref]);
  const threshold = loadSavedThresholdDb(kind);
  if (threshold !== null && threshold !== current.thresholdDb) out.push(['threshold', threshold]);
  return out;
}
