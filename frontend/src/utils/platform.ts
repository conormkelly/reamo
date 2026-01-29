/**
 * Platform Detection Utilities
 * Centralized browser/OS detection for platform-specific workarounds
 */

// Detect at module load time (safe for SSR with typeof check)
const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';

/**
 * Is running on iOS (iPhone, iPad, iPod)
 * Used for Touch Events workaround - Safari's Pointer Events drop rapid multi-touch
 */
export const isIOS = /iPad|iPhone|iPod/.test(ua);

/**
 * Is running in Safari browser (not Chrome/Firefox on iOS which also report Safari)
 */
export const isSafari = ua.includes('Safari') && !ua.includes('Chrome') && !ua.includes('Firefox');

/**
 * Is running in iOS Safari specifically
 * This combination has the most touch event bugs requiring workarounds
 */
export const isIOSSafari = isIOS && isSafari;

/**
 * Is running as a standalone PWA (added to home screen)
 * PWAs have different behavior than in-browser for some Safari bugs
 */
export const isPWA = typeof window !== 'undefined' &&
  window.matchMedia('(display-mode: standalone)').matches;

/**
 * Is running on a device with ProMotion display (120Hz)
 * Currently only iPad Pro and iPhone 13 Pro+ have this
 * Note: There's no reliable API to detect this, using device hints
 */
export const hasProMotion = isIOS && (
  // iPad Pro models have ProMotion
  (ua.includes('iPad') && window.devicePixelRatio >= 2) ||
  // iPhone 13 Pro and later (rough heuristic based on screen size)
  (ua.includes('iPhone') && window.screen.height >= 844)
);
