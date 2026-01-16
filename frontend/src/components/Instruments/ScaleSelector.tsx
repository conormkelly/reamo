/**
 * ScaleSelector Component
 * Dropdown to select scale type for chord generation
 */

import type { ReactElement } from 'react';
import { SCALE_TYPES, SCALE_DISPLAY_NAMES, type ScaleType } from '@/lib/music-theory';

export interface ScaleSelectorProps {
  /** Currently selected scale type */
  selectedScale: ScaleType;
  /** Callback when scale changes */
  onScaleChange: (scale: ScaleType) => void;
  className?: string;
}

export function ScaleSelector({
  selectedScale,
  onScaleChange,
  className = '',
}: ScaleSelectorProps): ReactElement {
  return (
    <select
      value={selectedScale}
      onChange={(e) => onScaleChange(e.target.value as ScaleType)}
      className={`
        bg-bg-surface text-text-primary text-sm
        border border-border-subtle rounded
        px-2 py-1.5
        focus:outline-none focus:ring-2 focus:ring-focus-ring
        ${className}
      `}
      aria-label="Scale type"
    >
      {SCALE_TYPES.map((scale) => (
        <option key={scale} value={scale}>
          {SCALE_DISPLAY_NAMES[scale]}
        </option>
      ))}
    </select>
  );
}
