/**
 * Volume conversion utilities
 * REAPER uses linear volume where: 0 = -inf, 1 = 0dB, 4 = +12dB
 */

// Conversion constant: Math.log(10) / 20 ≈ 0.115129...
// Used for: dB = 20 * log10(linear) = 20 * ln(linear) / ln(10)
// Which gives us: dB = ln(linear) * 20 / ln(10) ≈ ln(linear) * 8.68588963806
const DB_FACTOR = 8.68588963806;

/**
 * Convert linear volume to dB string for display
 * @param linearVolume - Linear volume value (0-4, where 1 = 0dB)
 * @returns Formatted string like "-12.50 dB" or "-inf dB"
 */
export function volumeToDbString(linearVolume: number): string {
  if (linearVolume < 0.00000002980232) {
    return '-inf dB';
  }
  const dB = Math.log(linearVolume) * DB_FACTOR;
  return `${dB.toFixed(2)} dB`;
}

/**
 * Convert linear volume to dB value
 * @param linearVolume - Linear volume value (0-4, where 1 = 0dB)
 * @returns dB value, or -Infinity for silence
 */
export function volumeToDb(linearVolume: number): number {
  if (linearVolume < 0.00000002980232) {
    return -Infinity;
  }
  return Math.log(linearVolume) * DB_FACTOR;
}

/**
 * Convert dB to linear volume
 * @param dB - dB value
 * @returns Linear volume value
 */
export function dbToVolume(dB: number): number {
  if (dB === -Infinity || dB < -150) {
    return 0;
  }
  return Math.exp(dB / DB_FACTOR);
}

/**
 * Convert fader position (0-1) to linear volume using power curve
 * This maps the fader range nicely: 0->0, ~0.75->1.0 (0dB), 1.0->4.0 (+12dB)
 * @param faderPosition - Fader position (0 to 1)
 * @returns Linear volume (0 to 4)
 */
export function faderToVolume(faderPosition: number): number {
  return Math.pow(faderPosition, 4) * 4;
}

/**
 * Convert linear volume to fader position (0-1)
 * Inverse of faderToVolume
 * @param linearVolume - Linear volume (0 to 4)
 * @returns Fader position (0 to 1)
 */
export function volumeToFader(linearVolume: number): number {
  if (linearVolume <= 0) return 0;
  return Math.pow(linearVolume / 4, 0.25);
}

/**
 * Convert fader position (0-1) directly to dB
 * @param faderPosition - Fader position (0 to 1)
 * @returns dB value
 */
export function faderToDb(faderPosition: number): number {
  return volumeToDb(faderToVolume(faderPosition));
}

/**
 * Convert dB to fader position (0-1)
 * @param dB - dB value
 * @returns Fader position (0 to 1)
 */
export function dbToFader(dB: number): number {
  return volumeToFader(dbToVolume(dB));
}

/**
 * Clamp a dB value to a reasonable display range
 * @param dB - dB value
 * @param min - Minimum dB (default -60)
 * @param max - Maximum dB (default +12)
 * @returns Clamped dB value
 */
export function clampDb(dB: number, min = -60, max = 12): number {
  if (dB === -Infinity) return min;
  return Math.max(min, Math.min(max, dB));
}
