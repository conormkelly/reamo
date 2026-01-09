/**
 * REAPER Constants
 * Section IDs and other constant values used across the app
 */

/**
 * REAPER action section IDs with full names.
 * These correspond to different contexts where actions can be executed.
 */
export const REAPER_SECTIONS: Record<number, string> = {
  0: 'Main',
  100: 'Main (Alt)',
  32060: 'MIDI Editor',
  32061: 'MIDI Event List',
  32062: 'MIDI Inline',
  32063: 'Media Explorer',
};

/**
 * Short section names for compact UI display (badges, tags).
 */
export const REAPER_SECTION_SHORT: Record<number, string> = {
  0: 'Main',
  100: 'Alt',
  32060: 'MIDI',
  32061: 'MIDI List',
  32062: 'MIDI Inline',
  32063: 'Explorer',
};

/**
 * Get section display name (short form) with fallback.
 */
export function getSectionName(sectionId: number, short = true): string {
  const map = short ? REAPER_SECTION_SHORT : REAPER_SECTIONS;
  return map[sectionId] ?? `Section ${sectionId}`;
}
