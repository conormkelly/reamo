/**
 * ColorPickerInput - Compact color swatch with hold-to-reset
 *
 * A tap or click opens the browser's own picker through a hidden colour input
 * over the swatch. Holding the swatch still for 500 ms resets the colour to
 * its default instead, and the click that ends that hold is cancelled so the
 * picker stays shut.
 *
 * Only pointer events drive the hold: they report mouse, touch and pen once
 * each, where the mouse events a browser emulates after a touch would run it
 * a second time.
 */

import { useRef, useCallback, useEffect } from 'react';

interface ColorPickerInputProps {
  label: string;
  value: string;
  onChange: (color: string) => void;
  defaultValue: string;
  /** Compact inline layout with smaller swatch */
  compact?: boolean;
}

const HOLD_DURATION = 500; // ms to hold for reset

/** How far, in CSS px, a press may drift and still count as holding still. */
const HOLD_MOVE_TOLERANCE = 10;

export function ColorPickerInput({
  label,
  value,
  onChange,
  defaultValue,
  compact = false,
}: ColorPickerInputProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const holdTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const holdOrigin = useRef<{ x: number; y: number } | null>(null);
  const didReset = useRef(false);

  const isDefault = value === defaultValue;

  const cancelHold = useCallback(() => {
    if (holdTimer.current) {
      clearTimeout(holdTimer.current);
      holdTimer.current = null;
    }
    holdOrigin.current = null;
  }, []);

  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      // Each press starts afresh: a reset whose click never came must not
      // cancel this press's click.
      didReset.current = false;
      cancelHold();
      // Only the primary button holds: a right-button press is for a menu.
      if (isDefault || e.button !== 0) return;
      holdOrigin.current = { x: e.clientX, y: e.clientY };
      holdTimer.current = setTimeout(() => {
        holdTimer.current = null;
        holdOrigin.current = null;
        didReset.current = true;
        onChange(defaultValue);
      }, HOLD_DURATION);
    },
    [isDefault, onChange, defaultValue, cancelHold]
  );

  // A finger that drifts is scrolling or dragging, not holding.
  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      const origin = holdOrigin.current;
      if (!origin) return;
      if (Math.hypot(e.clientX - origin.x, e.clientY - origin.y) > HOLD_MOVE_TOLERANCE) {
        cancelHold();
      }
    },
    [cancelHold]
  );

  // A click on the input opens the picker by itself; cancelling it keeps the
  // picker shut after a reset. A click on the swatch's border or dot, outside
  // the input, is passed on to the input.
  const handleClick = useCallback((e: React.MouseEvent) => {
    if (didReset.current) {
      didReset.current = false;
      e.preventDefault();
      return;
    }
    if (e.target !== inputRef.current) inputRef.current?.click();
  }, []);

  // A hold still running when the swatch leaves the page is abandoned.
  useEffect(() => cancelHold, [cancelHold]);

  const swatchSize = compact ? 'w-6 h-6' : 'w-10 h-10';
  const dotSize = compact ? 'w-2 h-2 -top-0.5 -right-0.5' : 'w-3 h-3 -top-1 -right-1';

  return (
    <div className={compact ? 'flex items-center gap-1.5' : ''}>
      <label className={compact ? 'text-xs text-text-secondary' : 'block text-xs text-text-secondary mb-1'}>
        {label}{compact && label ? ':' : ''}
      </label>
      <div
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={cancelHold}
        onPointerCancel={cancelHold}
        onPointerLeave={cancelHold}
        onClick={handleClick}
        className={`relative ${swatchSize} rounded border-2 border-border-default cursor-pointer hover:border-text-secondary transition-colors touch-none`}
        style={{ backgroundColor: value }}
        title={isDefault ? value : `${value} (hold to reset)`}
      >
        {/* Non-default indicator dot */}
        {!isDefault && (
          <div className={`absolute ${dotSize} bg-primary-hover rounded-full border border-bg-surface`} />
        )}
        {/* Hidden color input: covers the swatch inside its border, so most
            taps land on it and open the picker */}
        <input
          ref={inputRef}
          type="color"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className="absolute inset-0 opacity-0 cursor-pointer"
          tabIndex={-1}
        />
      </div>
    </div>
  );
}
