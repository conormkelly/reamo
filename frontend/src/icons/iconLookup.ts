/**
 * Look up Lucide icon components by name.
 *
 * Two-tier icon loading:
 * 1. Common icons (the curated set in commonIcons.ts) - loaded synchronously,
 *    covers 99% of DAW use cases
 * 2. Full library (every lucide icon) - lazy-loaded only when needed
 */

import type { ComponentType } from 'react';
import type { LucideProps } from 'lucide-react';
import { commonIcons, type CommonIconName } from './commonIcons';

export type LucideIcon = ComponentType<LucideProps>;

/**
 * Icon names that saved toolbar buttons and action sections may hold but that
 * lucide-react exports only as deprecated aliases. Each maps to the canonical
 * name of the same icon in the curated set, so a layout saved with "Trash2"
 * still shows the bin.
 */
const LEGACY_ICON_NAMES: ReadonlyMap<string, CommonIconName> = new Map<string, CommonIconName>([
  ['AlertCircle', 'CircleAlert'],
  ['AlertOctagon', 'OctagonAlert'],
  ['AlertTriangle', 'TriangleAlert'],
  ['AlignCenter', 'TextAlignCenter'],
  ['AlignLeft', 'TextAlignStart'],
  ['AlignRight', 'TextAlignEnd'],
  ['CheckCircle', 'CircleCheckBig'],
  ['CheckCircle2', 'CircleCheck'],
  ['CircleHelp', 'CircleQuestionMark'],
  ['Edit', 'SquarePen'],
  ['FileAudio', 'FileHeadphone'],
  ['Filter', 'Funnel'],
  ['FlipHorizontal', 'SquareCenterlineDashedHorizontal'],
  ['FlipVertical', 'SquareCenterlineDashedVertical'],
  ['HelpCircle', 'CircleQuestionMark'],
  ['History', 'RotateCcwClock'],
  ['Home', 'House'],
  ['Loader2', 'LoaderCircle'],
  ['MoreHorizontal', 'Ellipsis'],
  ['MoreVertical', 'EllipsisVertical'],
  ['Music', 'EighthNotes'],
  ['Music2', 'EighthNote'],
  ['Music3', 'HalfNote'],
  ['Music4', 'SixteenthNotes'],
  ['Sliders', 'SlidersVertical'],
  ['SortAsc', 'ArrowUpNarrowWide'],
  ['SortDesc', 'ArrowDownWideNarrow'],
  ['SplitSquareHorizontal', 'SquareSplitHorizontal'],
  ['SplitSquareVertical', 'SquareSplitVertical'],
  ['Trash2', 'Trash'],
  ['Unlock', 'LockOpen'],
  ['Wand2', 'WandSparkles'],
  ['Waves', 'WavesHorizontal'],
  ['XCircle', 'CircleX'],
]);

// Cache for lazy-loaded full icon library
let fullIconsCache: Record<string, LucideIcon> | null = null;
let fullIconsPromise: Promise<Record<string, LucideIcon>> | null = null;

/**
 * Convert kebab-case icon name to PascalCase for lucide-react lookup
 */
function kebabToPascal(name: string): string {
  return name
    .split('-')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join('');
}

function lookup(table: Record<string, LucideIcon>, name: string): LucideIcon | null {
  return Object.hasOwn(table, name) ? table[name] : null;
}

/**
 * Canonical lucide name for a stored icon name: legacy alias names (in
 * PascalCase or kebab-case) map to the icon's current name; any other name is
 * returned unchanged.
 */
export function canonicalIconName(name: string): string {
  return LEGACY_ICON_NAMES.get(name) ?? LEGACY_ICON_NAMES.get(kebabToPascal(name)) ?? name;
}

/**
 * Get icon component by name (sync - common icons only)
 * Returns null for icons not in the curated set.
 * For async access to all icons, use getIconComponentAsync.
 */
export function getIconComponent(name: string): LucideIcon | null {
  const canonical = canonicalIconName(name);
  const pascalName = kebabToPascal(canonical);

  // Curated set: exact (PascalCase) name, then kebab-case converted
  const common = lookup(commonIcons, canonical) ?? lookup(commonIcons, pascalName);
  if (common) return common;

  // Full library, once it has been loaded
  if (fullIconsCache) {
    return lookup(fullIconsCache, canonical) ?? lookup(fullIconsCache, pascalName);
  }

  return null;
}

/**
 * Lazy-load the full icon library.
 * Only call this when you need access to uncommon icons.
 */
async function loadFullIcons(): Promise<Record<string, LucideIcon>> {
  if (fullIconsCache) return fullIconsCache;

  if (!fullIconsPromise) {
    fullIconsPromise = import('lucide-react').then((mod) => {
      fullIconsCache = mod.icons as Record<string, LucideIcon>;
      return fullIconsCache;
    });
  }

  return fullIconsPromise;
}

/**
 * Get icon component by name (async - all icons)
 * Use this in IconPicker or when you need access to rare icons.
 */
export async function getIconComponentAsync(name: string): Promise<LucideIcon | null> {
  // Try common icons first (fast path)
  const commonIcon = getIconComponent(name);
  if (commonIcon) return commonIcon;

  // Lazy-load full library for uncommon icons
  const allIcons = await loadFullIcons();
  const canonical = canonicalIconName(name);
  return lookup(allIcons, canonical) ?? lookup(allIcons, kebabToPascal(canonical));
}
