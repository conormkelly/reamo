/**
 * Layout constants for responsive height calculations
 *
 * These constants centralize magic numbers that were previously scattered
 * across view files. See RESPONSIVE_TIMELINE_AND_MIXER.md for rationale.
 */

// =============================================================================
// SecondaryPanel Heights
// =============================================================================

/** Height when panel is collapsed (tab bar only) */
export const PANEL_HEIGHT_COLLAPSED = 44;

/** Height when panel is expanded */
export const PANEL_HEIGHT_EXPANDED = 140;

/** Panel animation duration in ms (must match SecondaryPanel CSS duration-200) */
export const PANEL_TRANSITION_MS = 200;

// =============================================================================
// Mixer Strip Layout
// =============================================================================

/**
 * Non-fader overhead in full mixer strip (portrait mode)
 * Includes: color bar (8) + track name (28) + pan (48) + M/S (30) + RecArm/Monitor (30) + selection footer (16) + gaps
 *
 * Breakdown:
 * - Color bar: h-2 = 8px
 * - Track name: py-2 + text = ~28px
 * - Pan control: ~44px + mb-1 = 48px
 * - M/S buttons: ~26px + mb-1 = 30px
 * - RecArm/Monitor: ~26px + mb-1 = 30px
 * - Selection footer: h-4 = 16px
 * - Main content pb-1: 4px
 * Total: ~164px
 *
 * Measure with debug helper if this seems wrong:
 * console.log('Actual overhead:', stripRef.current.offsetHeight - faderRef.current.offsetHeight)
 */
export const STRIP_OVERHEAD_FULL = 164;

/**
 * Non-fader overhead in compact mixer strip (landscape mode)
 * Includes: just track name + selection footer
 */
export const STRIP_OVERHEAD_COMPACT = 40;

/** Minimum fader height for touch usability in portrait */
export const MIN_FADER_PORTRAIT = 80;

/** Minimum fader height for touch usability in landscape */
export const MIN_FADER_LANDSCAPE = 50;

/** Maximum fader height as percentage of container (prevents overflow in edge cases) */
export const MAX_FADER_PERCENT = 0.7;

/** Vertical padding inside mixer content area (p-3 = 12px * 2 + pb-3 = 12px breathing room) */
export const MIXER_CONTENT_PADDING = 36;

// =============================================================================
// Timeline Layout
// =============================================================================

/**
 * Non-canvas overhead inside the Timeline component (navigate mode)
 *
 * Breakdown:
 * - Ruler: 32px
 * - Region labels bar: 25px
 * - Bottom bar (marker pills): h-5 = 20px
 * - Footer (navigate mode): ~44px
 * Total: ~121px
 *
 * In regions mode (no footer): 77px
 */
export const TIMELINE_OVERHEAD_NAVIGATE = 121;
export const TIMELINE_OVERHEAD_REGIONS = 77;

/** Padding inside timeline content area (p-3 = 24px + mt-2 = 8px) */
export const TIMELINE_CONTENT_PADDING = 32;

/** Minimum timeline canvas height */
export const MIN_TIMELINE_HEIGHT = 100;

/** Maximum timeline height as percentage of container (prevents overflow) */
export const MAX_TIMELINE_PERCENT = 0.8;

// =============================================================================
// Responsive Breakpoints
// =============================================================================

/** Width threshold below which we consider the device "phone-sized" */
export const PHONE_MAX_WIDTH = 550;

/** Width threshold above which we consider the device "tablet-sized" */
export const TABLET_MIN_WIDTH = 768;
