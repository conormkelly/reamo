/**
 * Validation utilities for form inputs
 *
 * Consolidates time parsing, color validation, and range validation
 * patterns that were previously duplicated across modal components.
 */

/**
 * Parse time input string to seconds
 *
 * Supports multiple formats:
 * - Plain seconds: "45.5" → 45.5
 * - MM:SS format: "1:23" → 83
 * - MM:SS.ms format: "1:23.45" → 83.45
 * - HH:MM:SS format: "1:02:03" → 3723
 * - HH:MM:SS.ms format: "1:02:03.5" → 3723.5
 *
 * @param input - Time string to parse
 * @returns Seconds as number, or null if invalid
 *
 * @example
 * parseTimeInput("1:23.45")   // 83.45
 * parseTimeInput("1:02:03.5") // 3723.5
 * parseTimeInput("45.5")      // 45.5
 * parseTimeInput("")          // null
 * parseTimeInput("invalid")   // null
 */
export function parseTimeInput(input: string): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;

  // Try plain seconds first (no colons)
  if (!trimmed.includes(':')) {
    const seconds = parseFloat(trimmed);
    if (!isNaN(seconds) && isFinite(seconds) && seconds >= 0) {
      return seconds;
    }
    return null;
  }

  // Parse as MM:SS or HH:MM:SS
  const parts = trimmed.split(':');

  if (parts.length === 2) {
    // MM:SS or MM:SS.ms
    const mins = parseInt(parts[0], 10);
    const secs = parseFloat(parts[1]);
    if (!isNaN(mins) && !isNaN(secs) && mins >= 0 && secs >= 0) {
      return mins * 60 + secs;
    }
  } else if (parts.length === 3) {
    // HH:MM:SS or HH:MM:SS.ms
    const hours = parseInt(parts[0], 10);
    const mins = parseInt(parts[1], 10);
    const secs = parseFloat(parts[2]);
    if (!isNaN(hours) && !isNaN(mins) && !isNaN(secs) && hours >= 0 && mins >= 0 && secs >= 0) {
      return hours * 3600 + mins * 60 + secs;
    }
  }

  return null;
}

/**
 * Format seconds to time string for display in inputs
 *
 * @param seconds - Time in seconds
 * @param precision - Decimal places for seconds (default: 3)
 * @returns Formatted string: "MM:SS.mmm" or "HH:MM:SS.mmm" for ≥1 hour
 *
 * @example
 * formatTimeForInput(83.456)    // "1:23.456"
 * formatTimeForInput(3723.5)    // "1:02:03.500"
 * formatTimeForInput(45.5, 1)   // "0:45.5"
 */
export function formatTimeForInput(seconds: number, precision: number = 3): string {
  const absSeconds = Math.abs(seconds);
  const sign = seconds < 0 ? '-' : '';

  const hours = Math.floor(absSeconds / 3600);
  const mins = Math.floor((absSeconds % 3600) / 60);
  const secs = absSeconds % 60;

  // Format seconds with proper padding
  let secsStr: string;
  if (precision > 0) {
    // Use toFixed for decimals, ensure integer part is padded to 2 digits
    const fixed = secs.toFixed(precision);
    const [intPart, decPart] = fixed.split('.');
    secsStr = `${intPart.padStart(2, '0')}.${decPart}`;
  } else {
    // Round when no decimals are shown
    secsStr = Math.round(secs).toString().padStart(2, '0');
  }

  if (hours > 0) {
    return `${sign}${hours}:${mins.toString().padStart(2, '0')}:${secsStr}`;
  }
  return `${sign}${mins}:${secsStr}`;
}

/**
 * Check if a string is a valid partial hex color (for input onChange)
 *
 * Allows incomplete values while typing:
 * - Empty string
 * - "#" alone
 * - "#f" through "#ffffff"
 * - "f" through "ffffff" (without #)
 *
 * @param value - String to validate
 * @returns true if valid partial hex color
 *
 * @example
 * isPartialHexColor("")        // true (empty is valid during typing)
 * isPartialHexColor("#ff")     // true
 * isPartialHexColor("#ff00ff") // true
 * isPartialHexColor("#gggggg") // false
 */
export function isPartialHexColor(value: string): boolean {
  return /^#?[0-9a-f]{0,6}$/i.test(value);
}

/**
 * Check if a string is a complete valid hex color (for form submission)
 *
 * Requires exactly 6 hex digits, with optional # prefix.
 *
 * @param value - String to validate
 * @returns true if valid complete hex color
 *
 * @example
 * isCompleteHexColor("#ff00ff") // true
 * isCompleteHexColor("ff00ff")  // true
 * isCompleteHexColor("#ff")     // false (incomplete)
 * isCompleteHexColor("")        // false
 */
export function isCompleteHexColor(value: string): boolean {
  return /^#?[0-9a-f]{6}$/i.test(value);
}

/**
 * Normalize hex color to include # prefix
 *
 * @param value - Hex color with or without #
 * @returns Hex color with # prefix, or null if invalid
 *
 * @example
 * normalizeHexColor("ff00ff")  // "#ff00ff"
 * normalizeHexColor("#FF00FF") // "#ff00ff"
 * normalizeHexColor("invalid") // null
 */
export function normalizeHexColor(value: string): string | null {
  if (!isCompleteHexColor(value)) return null;
  const hex = value.startsWith('#') ? value : `#${value}`;
  return hex.toLowerCase();
}

/**
 * Result type for time range validation
 */
export type TimeRangeResult =
  | { valid: true; start: number; end: number }
  | { valid: false; error: string };

/**
 * Validate a time range (start/end pair)
 *
 * - Auto-swaps if end < start
 * - Validates minimum length
 *
 * @param start - Start time in seconds
 * @param end - End time in seconds
 * @param minLength - Minimum required length in seconds (default: 0.01)
 * @returns Validated range with auto-swap, or error
 *
 * @example
 * validateTimeRange(10, 20)       // { valid: true, start: 10, end: 20 }
 * validateTimeRange(20, 10)       // { valid: true, start: 10, end: 20 } (swapped)
 * validateTimeRange(10, 10)       // { valid: false, error: "Selection must have a length" }
 * validateTimeRange(10, 10.005)   // { valid: false, error: "Selection must have a length" }
 */
export function validateTimeRange(
  start: number,
  end: number,
  minLength: number = 0.01
): TimeRangeResult {
  // Auto-swap if needed
  let actualStart = start;
  let actualEnd = end;
  if (end < start) {
    actualStart = end;
    actualEnd = start;
  }

  // Check minimum length (use small epsilon for floating point comparison)
  const length = actualEnd - actualStart;
  const epsilon = 1e-9;
  if (length < minLength - epsilon) {
    return { valid: false, error: 'Selection must have a length' };
  }

  return { valid: true, start: actualStart, end: actualEnd };
}

/**
 * Validate a positive integer input (for bar numbers, etc.)
 *
 * @param value - String to validate
 * @param min - Minimum allowed value (default: 1)
 * @returns Parsed integer, or null if invalid
 *
 * @example
 * parsePositiveInt("5")    // 5
 * parsePositiveInt("0")    // null (below minimum)
 * parsePositiveInt("-1")   // null
 * parsePositiveInt("1.5")  // null (not an integer)
 */
export function parsePositiveInt(value: string, min: number = 1): number | null {
  const trimmed = value.trim();
  const num = parseInt(trimmed, 10);

  // Must be a valid integer (not float)
  if (isNaN(num) || num.toString() !== trimmed || num < min) {
    return null;
  }

  return num;
}
