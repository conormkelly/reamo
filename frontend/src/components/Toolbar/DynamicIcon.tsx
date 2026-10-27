/**
 * DynamicIcon - Renders a Lucide icon by name
 *
 * Common icons render synchronously; DynamicIconAsync lazy-loads the full
 * library for the rest (see icons/iconLookup).
 */

import { useState, useEffect } from 'react';
import { getIconComponent, getIconComponentAsync, type LucideIcon } from '../../icons/iconLookup';

interface DynamicIconProps {
  name: string;
  size?: number;
  className?: string;
  style?: React.CSSProperties;
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
