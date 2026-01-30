/**
 * TunerMeter - Cents deviation meter
 *
 * Shows pitch deviation from -50 to +50 cents with color-coded indicator:
 * - Green: |cents| < 2 (in tune)
 * - Yellow: |cents| < 10 (close)
 * - Red: |cents| >= 10 (out of tune)
 *
 * Uses CSS transitions for smooth animation at 30Hz updates.
 * Supports disabled state for "no signal" display.
 */

import type { ReactElement } from 'react';

export interface TunerMeterProps {
  cents: number;
  inTune: boolean;
  /** Show muted placeholder state (no signal) */
  disabled?: boolean;
}

export function TunerMeter({ cents, inTune, disabled }: TunerMeterProps): ReactElement {
  // Clamp cents to display range
  const clampedCents = Math.max(-50, Math.min(50, cents));

  // Calculate indicator position (0-100%), center when disabled
  const position = disabled ? 50 : 50 + clampedCents;

  // Determine color based on deviation (muted when disabled)
  const absCents = Math.abs(cents);
  let indicatorColor: string;
  let bgGlow: string;

  if (disabled) {
    indicatorColor = 'bg-text-muted';
    bgGlow = '';
  } else if (inTune || absCents < 2) {
    indicatorColor = 'bg-success';
    bgGlow = 'shadow-[0_0_12px_rgba(var(--success-rgb),0.5)]';
  } else if (absCents < 10) {
    indicatorColor = 'bg-warning';
    bgGlow = '';
  } else {
    indicatorColor = 'bg-error';
    bgGlow = '';
  }

  return (
    <div className="w-full max-w-xs flex flex-col items-center gap-2">
      {/* Meter bar */}
      <div className="relative w-full h-3 bg-bg-elevated rounded-full overflow-hidden">
        {/* Center marker */}
        <div className="absolute top-0 bottom-0 left-1/2 w-0.5 bg-border-muted -translate-x-1/2 z-10" />

        {/* Tick marks */}
        <div className="absolute top-0 bottom-0 left-0 right-0 flex justify-between px-1">
          {[-50, -25, 0, 25, 50].map((tick) => (
            <div
              key={tick}
              className={`w-px h-full ${tick === 0 ? 'bg-text-tertiary' : 'bg-border-muted'}`}
              style={{ opacity: tick === 0 ? 1 : 0.5 }}
            />
          ))}
        </div>

        {/* Indicator */}
        <div
          className={`absolute top-0 bottom-0 w-3 rounded-full transition-[left] duration-50 ease-out ${indicatorColor} ${bgGlow}`}
          style={{
            left: `calc(${position}% - 6px)`,
          }}
        />
      </div>

      {/* Labels */}
      <div className="w-full flex justify-between text-xs text-text-muted px-1">
        <span>−50</span>
        <span
          className={`font-medium ${
            disabled
              ? 'text-text-muted'
              : inTune
                ? 'text-success'
                : absCents < 10
                  ? 'text-warning'
                  : 'text-error'
          }`}
        >
          {disabled ? '—' : `${cents >= 0 ? '+' : ''}${cents.toFixed(1)}¢`}
        </span>
        <span>+50</span>
      </div>
    </div>
  );
}
