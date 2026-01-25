/**
 * TextSizeControl - Reusable font size adjustment control
 * Layout: [ - ] [ Aa icon ] [ + ]
 */

import type { ReactElement } from 'react';
import { ALargeSmall, Minus, Plus } from 'lucide-react';

export interface TextSizeControlProps {
  value: number;
  onChange: (size: number) => void;
  min?: number;
  max?: number;
  step?: number;
}

export function TextSizeControl({
  value,
  onChange,
  min = 8,
  max = 48,
  step = 2,
}: TextSizeControlProps): ReactElement {
  const canDecrease = value > min;
  const canIncrease = value < max;

  return (
    <div className="inline-flex items-center gap-0.5 bg-bg-surface rounded-lg p-0.5">
      <button
        onClick={() => onChange(Math.max(min, value - step))}
        disabled={!canDecrease}
        className={`p-1.5 rounded transition-colors ${
          canDecrease
            ? 'hover:bg-bg-elevated text-text-tertiary'
            : 'text-text-disabled cursor-not-allowed'
        }`}
        title="Decrease font size"
        aria-label="Decrease font size"
      >
        <Minus size={14} />
      </button>
      <div className="px-1 text-text-secondary" title={`Font size: ${value}px`}>
        <ALargeSmall size={18} />
      </div>
      <button
        onClick={() => onChange(Math.min(max, value + step))}
        disabled={!canIncrease}
        className={`p-1.5 rounded transition-colors ${
          canIncrease
            ? 'hover:bg-bg-elevated text-text-tertiary'
            : 'text-text-disabled cursor-not-allowed'
        }`}
        title="Increase font size"
        aria-label="Increase font size"
      >
        <Plus size={14} />
      </button>
    </div>
  );
}
