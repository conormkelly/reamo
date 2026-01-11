/**
 * MixerModeSelector Component
 * Segmented control for switching between mixer modes.
 */

import type { ReactElement } from 'react';
import type { MixerMode } from './MixerStrip';

export interface MixerModeSelectorProps {
  /** Current mode */
  mode: MixerMode;
  /** Mode change handler */
  onModeChange: (mode: MixerMode) => void;
  className?: string;
}

const MODES: { value: MixerMode; label: string; title: string }[] = [
  { value: 'volume', label: 'Vol', title: 'Volume mode - maximum fader size' },
  { value: 'mix', label: 'Mix', title: 'Mix mode - faders, pan, and record arm' },
  { value: 'sends', label: 'Sends', title: 'Sends mode - control send levels' },
];

/**
 * Segmented control for mixer mode selection.
 *
 * Modes:
 * - Volume: Maximum fader size, M/S only
 * - Mix: Full controls including pan and rec arm
 * - Sends: Gold faders for send levels (future)
 */
export function MixerModeSelector({
  mode,
  onModeChange,
  className = '',
}: MixerModeSelectorProps): ReactElement {
  return (
    <div
      className={`flex bg-bg-surface rounded-lg p-0.5 ${className}`}
      role="tablist"
      aria-label="Mixer mode"
    >
      {MODES.map(({ value, label, title }) => {
        const isActive = mode === value;
        const isDisabled = value === 'sends'; // Future feature

        return (
          <button
            key={value}
            onClick={() => !isDisabled && onModeChange(value)}
            disabled={isDisabled}
            role="tab"
            aria-selected={isActive}
            title={isDisabled ? `${title} (coming soon)` : title}
            className={`px-3 py-1.5 text-sm font-medium rounded-md transition-colors ${
              isActive
                ? 'bg-primary text-text-on-primary'
                : isDisabled
                  ? 'text-text-disabled cursor-not-allowed'
                  : 'text-text-secondary hover:text-text-primary hover:bg-bg-elevated'
            }`}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}
