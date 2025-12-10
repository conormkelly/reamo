/**
 * Color conversion utilities
 * REAPER uses colors in 0xaarrggbb format (alpha, red, green, blue)
 */

/**
 * Convert REAPER color to CSS hex string
 * @param reaperColor - Color in 0xaarrggbb format (0 means no custom color)
 * @returns CSS hex color string like "#ff5500" or null if no custom color
 */
export function reaperColorToHex(reaperColor: number): string | null {
  if (reaperColor === 0) {
    return null;
  }
  // Extract RGB from 0xaarrggbb format
  // The format is actually stored as a 32-bit integer
  const hex = (reaperColor | 0x1000000).toString(16).slice(-6);
  return `#${hex}`;
}

/**
 * Convert REAPER color to RGB components
 * @param reaperColor - Color in 0xaarrggbb format
 * @returns RGB object or null if no custom color
 */
export function reaperColorToRgb(
  reaperColor: number
): { r: number; g: number; b: number } | null {
  if (reaperColor === 0) {
    return null;
  }
  return {
    r: (reaperColor >> 16) & 0xff,
    g: (reaperColor >> 8) & 0xff,
    b: reaperColor & 0xff,
  };
}

/**
 * Convert REAPER color to CSS rgba string with optional alpha override
 * @param reaperColor - Color in 0xaarrggbb format
 * @param alpha - Alpha value (0-1), defaults to extracting from color
 * @returns CSS rgba string or null if no custom color
 */
export function reaperColorToRgba(
  reaperColor: number,
  alpha?: number
): string | null {
  if (reaperColor === 0) {
    return null;
  }
  const r = (reaperColor >> 16) & 0xff;
  const g = (reaperColor >> 8) & 0xff;
  const b = reaperColor & 0xff;
  const a = alpha ?? ((reaperColor >> 24) & 0xff) / 255;
  return `rgba(${r}, ${g}, ${b}, ${a})`;
}

/**
 * Get a contrasting text color (black or white) for a background color
 * @param reaperColor - Background color in 0xaarrggbb format
 * @returns "black" or "white" for optimal contrast
 */
export function getContrastColor(reaperColor: number): 'black' | 'white' {
  if (reaperColor === 0) {
    return 'white'; // Default for no custom color
  }
  const r = (reaperColor >> 16) & 0xff;
  const g = (reaperColor >> 8) & 0xff;
  const b = reaperColor & 0xff;

  // Calculate relative luminance using sRGB formula
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;

  return luminance > 0.5 ? 'black' : 'white';
}

/**
 * Darken or lighten a REAPER color
 * @param reaperColor - Color in 0xaarrggbb format
 * @param amount - Amount to adjust (-1 to 1, negative = darker)
 * @returns Adjusted color or original if no custom color
 */
export function adjustBrightness(reaperColor: number, amount: number): number {
  if (reaperColor === 0) {
    return 0;
  }

  const a = (reaperColor >> 24) & 0xff;
  let r = (reaperColor >> 16) & 0xff;
  let g = (reaperColor >> 8) & 0xff;
  let b = reaperColor & 0xff;

  if (amount > 0) {
    // Lighten
    r = Math.min(255, r + (255 - r) * amount);
    g = Math.min(255, g + (255 - g) * amount);
    b = Math.min(255, b + (255 - b) * amount);
  } else {
    // Darken
    r = Math.max(0, r * (1 + amount));
    g = Math.max(0, g * (1 + amount));
    b = Math.max(0, b * (1 + amount));
  }

  return (a << 24) | (Math.round(r) << 16) | (Math.round(g) << 8) | Math.round(b);
}
