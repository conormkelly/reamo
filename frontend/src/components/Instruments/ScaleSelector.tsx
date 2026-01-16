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
    <div className={`flex items-center gap-1.5 ${className}`}>
      <label htmlFor="chord-scale" className="text-text-secondary text-sm">
        Scale
      </label>
      <select
        id="chord-scale"
        value={selectedScale}
        onChange={(e) => onScaleChange(e.target.value as ScaleType)}
        className="
          bg-bg-surface text-text-primary text-sm
          border border-border-subtle rounded
          px-1.5 py-1.5
          focus:outline-none focus:ring-2 focus:ring-focus-ring
        "
        aria-label="Scale type"
      >
        {SCALE_TYPES.map((scale) => (
          <option key={scale} value={scale}>
            {SCALE_DISPLAY_NAMES[scale]}
          </option>
        ))}
      </select>
    </div>
  );
}
