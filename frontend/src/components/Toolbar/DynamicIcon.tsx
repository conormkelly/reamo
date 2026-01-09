/**
 * DynamicIcon - Renders a Lucide icon by name
 *
 * This component isolates the `icons` object import to a single location,
 * allowing the IconPicker to be lazy-loaded. Use this for rendering
 * user-selected icons by name.
 */

import { icons, type LucideIcon } from 'lucide-react';

interface DynamicIconProps {
  name: string;
  size?: number;
  className?: string;
  style?: React.CSSProperties;
}

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
 * Get icon component by name (kebab-case or PascalCase)
 */
export function getIconComponent(name: string): LucideIcon | null {
  // Try exact match first (PascalCase)
  if (name in icons) {
    return icons[name as keyof typeof icons] as LucideIcon;
  }
  // Convert kebab-case to PascalCase
  const pascalName = kebabToPascal(name);
  return (icons as Record<string, LucideIcon>)[pascalName] || null;
}

/**
 * Renders a Lucide icon by name
 */
export function DynamicIcon({ name, size = 20, className, style }: DynamicIconProps) {
  const IconComponent = getIconComponent(name);
  if (!IconComponent) return null;
  return <IconComponent size={size} className={className} style={style} />;
}
