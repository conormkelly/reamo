/**
 * DynamicIcon - Renders a Lucide icon by name
 *
 * Two-tier icon loading:
 * 1. Common icons (292) - loaded synchronously, covers 99% of DAW use cases
 * 2. Full library (1663) - lazy-loaded only when needed
 *
 * This reduces the main bundle by ~150-200 kB.
 */

import { useState, useEffect, type ComponentType } from 'react';
import { commonIcons, type CommonIconName } from '../../icons/commonIcons';
import type { LucideProps } from 'lucide-react';

type LucideIcon = ComponentType<LucideProps>;

interface DynamicIconProps {
  name: string;
  size?: number;
  className?: string;
  style?: React.CSSProperties;
}

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

/**
 * Get icon component by name (sync - common icons only)
 * Returns null for icons not in the curated set.
 * For async access to all icons, use getIconComponentAsync.
 */
export function getIconComponent(name: string): LucideIcon | null {
  // Try exact match in common icons first (PascalCase)
  if (name in commonIcons) {
    return commonIcons[name as CommonIconName];
  }

  // Convert kebab-case to PascalCase and try again
  const pascalName = kebabToPascal(name);
  if (pascalName in commonIcons) {
    return commonIcons[pascalName as CommonIconName];
  }

  // Check if we've already loaded the full library
  if (fullIconsCache) {
    return fullIconsCache[name] || fullIconsCache[pascalName] || null;
  }

  // Not in common icons and full library not loaded
  return null;
}

/**
 * Lazy-load the full icon library (1663 icons)
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
  const pascalName = kebabToPascal(name);
  return allIcons[name] || allIcons[pascalName] || null;
}

/**
 * Check if an icon exists (sync for common, async check for full library)
 */
export function isCommonIcon(name: string): boolean {
  const pascalName = kebabToPascal(name);
  return name in commonIcons || pascalName in commonIcons;
}

/**
 * Renders a Lucide icon by name (sync rendering)
 * Uses common icons for instant rendering.
 */
export function DynamicIcon({ name, size = 20, className, style }: DynamicIconProps) {
  const IconComponent = getIconComponent(name);
  if (!IconComponent) return null;
  return <IconComponent size={size} className={className} style={style} />;
}

/**
 * Renders a Lucide icon by name with async fallback
 * First tries common icons (instant), then lazy-loads full library if needed.
 */
export function DynamicIconAsync({ name, size = 20, className, style }: DynamicIconProps) {
  const [IconComponent, setIconComponent] = useState<LucideIcon | null>(() =>
    getIconComponent(name)
  );
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    // Reset when name changes
    const syncIcon = getIconComponent(name);
    if (syncIcon) {
      setIconComponent(syncIcon);
      setLoading(false);
      return;
    }

    // Not in common icons, try loading full library
    setLoading(true);
    getIconComponentAsync(name).then((icon) => {
      setIconComponent(icon);
      setLoading(false);
    });
  }, [name]);

  if (loading) {
    // Could show a placeholder here
    return null;
  }

  if (!IconComponent) return null;
  return <IconComponent size={size} className={className} style={style} />;
}
