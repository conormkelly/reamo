/**
 * Shared styling utilities for track control buttons.
 * Extracted to reduce duplication while preserving explicit button implementations.
 *
 * Used by: MuteButton, SoloButton, RecordArmButton, MonitorButton, MasterMonoButton
 */

/**
 * Returns inactive background classes based on track selection state.
 * All track control buttons use this pattern for consistent visual hierarchy:
 * - Selected track: lighter background (bg-surface)
 * - Unselected track: darker background (bg-deep)
 */
export function getInactiveClasses(isSelected: boolean): string {
  return isSelected
    ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
    : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';
}

/**
 * Returns the mixer locked classes if applicable.
 * When mixer is locked, buttons appear disabled but remain interactive
 * (click handlers check mixerLocked and early-return).
 */
export function getLockedClasses(mixerLocked: boolean): string {
  return mixerLocked ? 'opacity-50 cursor-not-allowed' : '';
}

/**
 * Base class string for all track control buttons.
 * Individual buttons compose this with their specific padding and active classes.
 */
export const trackControlBaseClasses = 'rounded text-sm font-medium transition-colors';
