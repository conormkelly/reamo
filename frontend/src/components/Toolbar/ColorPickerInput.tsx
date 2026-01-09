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
}

const HOLD_DURATION = 500; // ms to hold for reset

export function ColorPickerInput({
  label,
  value,
  onChange,
  defaultValue,
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

  return (
    <div>
      <label className="block text-xs text-gray-400 mb-1">{label}</label>
      <div
        onMouseDown={handleMouseDown}
        onMouseUp={handleMouseUp}
        onMouseLeave={handleMouseLeave}
        onTouchStart={handleMouseDown}
        onTouchEnd={handleMouseUp}
        className="relative w-10 h-10 rounded border-2 border-gray-600 cursor-pointer hover:border-gray-400 transition-colors"
        style={{ backgroundColor: value }}
        title={isDefault ? value : `${value} (hold to reset)`}
      >
        {/* Non-default indicator dot */}
        {!isDefault && (
          <div className="absolute -top-1 -right-1 w-3 h-3 bg-blue-500 rounded-full border border-gray-800" />
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
