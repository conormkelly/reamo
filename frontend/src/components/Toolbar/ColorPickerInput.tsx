/**
 * ColorPickerInput - Compact color swatch with hold-to-reset
 * Click to open system color picker, hold 500ms to reset to default
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

export function ColorPickerInput({
  label,
  value,
  onChange,
  defaultValue,
  compact = false,
}: ColorPickerInputProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const holdTimer = useRef<number | null>(null);
  const didReset = useRef(false);

  const isDefault = value === defaultValue;

  const handleMouseDown = useCallback(() => {
    didReset.current = false;
    holdTimer.current = window.setTimeout(() => {
      if (!isDefault) {
        onChange(defaultValue);
        didReset.current = true;
      }
    }, HOLD_DURATION);
  }, [isDefault, onChange, defaultValue]);

  const handleMouseUp = useCallback(() => {
    if (holdTimer.current) {
      clearTimeout(holdTimer.current);
      holdTimer.current = null;
    }
    // Only open picker if we didn't just reset
    if (!didReset.current) {
      inputRef.current?.click();
    }
  }, []);

  const handleMouseLeave = useCallback(() => {
    if (holdTimer.current) {
      clearTimeout(holdTimer.current);
      holdTimer.current = null;
    }
  }, []);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (holdTimer.current) {
        clearTimeout(holdTimer.current);
      }
    };
  }, []);

  const swatchSize = compact ? 'w-6 h-6' : 'w-10 h-10';
  const dotSize = compact ? 'w-2 h-2 -top-0.5 -right-0.5' : 'w-3 h-3 -top-1 -right-1';

  return (
    <div className={compact ? 'flex items-center gap-1.5' : ''}>
      <label className={compact ? 'text-xs text-text-secondary' : 'block text-xs text-text-secondary mb-1'}>
        {label}{compact ? ':' : ''}
      </label>
      <div
        onMouseDown={handleMouseDown}
        onMouseUp={handleMouseUp}
        onMouseLeave={handleMouseLeave}
        onTouchStart={handleMouseDown}
        onTouchEnd={handleMouseUp}
        className={`relative ${swatchSize} rounded border-2 border-border-default cursor-pointer hover:border-text-secondary transition-colors touch-none`}
        style={{ backgroundColor: value }}
        title={isDefault ? value : `${value} (hold to reset)`}
      >
        {/* Non-default indicator dot */}
        {!isDefault && (
          <div className={`absolute ${dotSize} bg-primary-hover rounded-full border border-bg-surface`} />
        )}
        {/* Hidden color input */}
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
