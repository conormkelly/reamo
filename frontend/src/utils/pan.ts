/**
 * Pan conversion utilities
 * REAPER uses pan values from -1 (full left) to +1 (full right)
 */

/**
 * Convert pan value to display string
 * @param pan - Pan value (-1 to 1)
 * @returns Formatted string like "50%L", "center", or "50%R"
 */
export function panToString(pan: number): string {
  if (Math.abs(pan) < 0.001) {
    return 'center';
  }
  if (pan > 0) {
    return `${Math.round(pan * 100)}%R`;
  }
  return `${Math.round(Math.abs(pan) * 100)}%L`;
}

/**
 * Convert pan value to percentage (0-100)
 * @param pan - Pan value (-1 to 1)
 * @returns Percentage where 0 = full left, 50 = center, 100 = full right
 */
export function panToPercent(pan: number): number {
  return (pan + 1) * 50;
}

/**
 * Convert percentage to pan value
 * @param percent - Percentage (0-100)
 * @returns Pan value (-1 to 1)
 */
export function percentToPan(percent: number): number {
  return (percent / 50) - 1;
}

/**
 * Check if pan is approximately centered
 * @param pan - Pan value (-1 to 1)
 * @param threshold - How close to 0 is considered center (default 0.01)
 * @returns True if centered
 */
export function isCentered(pan: number, threshold = 0.01): boolean {
  return Math.abs(pan) < threshold;
}

/**
 * Clamp pan value to valid range
 * @param pan - Pan value
 * @returns Clamped pan (-1 to 1)
 */
export function clampPan(pan: number): number {
  return Math.max(-1, Math.min(1, pan));
}
