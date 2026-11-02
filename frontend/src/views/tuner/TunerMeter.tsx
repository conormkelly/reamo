/**
 * TunerMeter - Cents deviation meter, -50 to +50
 *
 * The needle (tunerDisplay.ts decides its tone):
 * - hidden: no pitch, so no needle
 * - moving: grey, the pitch isn't stable yet (an attack, a peg turning,
 *   several notes)
 * - inTune: green; close: yellow, under 10 cents; off: red
 *
 * Uses CSS transitions for smooth movement at 30 Hz updates.
 */

import type { ReactElement } from 'react';
import type { NeedleTone } from './tunerDisplay';

export interface TunerMeterProps {
  cents: number;
  tone: NeedleTone;
}

const NEEDLE_CLASS: Record<Exclude<NeedleTone, 'hidden'>, string> = {
  moving: 'bg-text-muted',
  inTune: 'bg-success shadow-[0_0_12px_rgba(var(--success-rgb),0.5)]',
  close: 'bg-warning',
  off: 'bg-error',
};

const LABEL_CLASS: Record<NeedleTone, string> = {
  hidden: 'text-text-muted',
  moving: 'text-text-secondary',
  inTune: 'text-success',
  close: 'text-warning',
  off: 'text-error',
};

export function TunerMeter({ cents, tone }: TunerMeterProps): ReactElement {
  const position = 50 + Math.max(-50, Math.min(50, cents));
  // To the tenth shown, with no "-0.0"
  const tenths = Math.round(cents * 10) / 10 || 0;

  return (
    <div className="w-full max-w-xs flex flex-col items-center gap-2">
      {/* Meter bar */}
      <div className="relative w-full h-3 bg-bg-elevated rounded-full overflow-hidden" aria-hidden="true">
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

        {tone !== 'hidden' && (
          <div
            data-testid="tuner-needle"
            data-tone={tone}
            className={`absolute top-0 bottom-0 w-3 rounded-full transition-[left] duration-50 ease-out ${NEEDLE_CLASS[tone]}`}
            style={{ left: `calc(${position}% - 6px)` }}
          />
        )}
      </div>

      {/* Labels */}
      <div className="w-full flex justify-between text-xs text-text-muted px-1">
        <span aria-hidden="true">−50</span>
        <span className={`font-medium ${LABEL_CLASS[tone]}`}>
          {tone === 'hidden' ? '—' : `${tenths >= 0 ? '+' : ''}${tenths.toFixed(1)}¢`}
        </span>
        <span aria-hidden="true">+50</span>
      </div>
    </div>
  );
}
