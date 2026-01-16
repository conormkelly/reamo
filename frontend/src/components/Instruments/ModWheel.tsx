/**
 * ModWheel Component
 * Vertical touch strip for MIDI CC (typically CC1 = Mod Wheel)
 * Rate-limited to 50Hz to avoid flooding MIDI
 */

import { useState, useCallback, useRef, type ReactElement, type PointerEvent } from 'react';

export interface ModWheelProps {
  /** Callback when value changes */
  onChange: (value: number) => void;
  /** Initial value (0-127) */
  initialValue?: number;
  /** Label to display */
  label?: string;
  className?: string;
}

/** Rate limit in ms (50Hz = 20ms) */
const RATE_LIMIT_MS = 20;

export function ModWheel({
  onChange,
  initialValue = 0,
  label = 'MOD',
  className = '',
}: ModWheelProps): ReactElement {
  const [value, setValue] = useState(initialValue);
  const [isActive, setIsActive] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastSendRef = useRef<number>(0);
  const pendingValueRef = useRef<number | null>(null);
  const rafRef = useRef<number | null>(null);

  const sendValue = useCallback(
    (newValue: number) => {
      const now = Date.now();
      const timeSinceLastSend = now - lastSendRef.current;

      if (timeSinceLastSend >= RATE_LIMIT_MS) {
        lastSendRef.current = now;
        onChange(newValue);
        pendingValueRef.current = null;
      } else {
        // Schedule send after rate limit
        pendingValueRef.current = newValue;
        if (rafRef.current === null) {
          rafRef.current = window.setTimeout(() => {
            rafRef.current = null;
            if (pendingValueRef.current !== null) {
              lastSendRef.current = Date.now();
              onChange(pendingValueRef.current);
              pendingValueRef.current = null;
            }
          }, RATE_LIMIT_MS - timeSinceLastSend);
        }
      }
    },
    [onChange]
  );

  const calculateValue = useCallback((clientY: number): number => {
    if (!containerRef.current) return 0;
    const rect = containerRef.current.getBoundingClientRect();
    // Invert: top = 127, bottom = 0
    const normalized = 1 - (clientY - rect.top) / rect.height;
    return Math.round(Math.max(0, Math.min(127, normalized * 127)));
  }, []);

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      e.stopPropagation();
      containerRef.current?.setPointerCapture(e.pointerId);
      setIsActive(true);
      const newValue = calculateValue(e.clientY);
      setValue(newValue);
      sendValue(newValue);
    },
    [calculateValue, sendValue]
  );

  const handlePointerMove = useCallback(
    (e: PointerEvent) => {
      if (!isActive) return;
      const newValue = calculateValue(e.clientY);
      setValue(newValue);
      sendValue(newValue);
    },
    [isActive, calculateValue, sendValue]
  );

  const handlePointerUp = useCallback(
    (e: PointerEvent) => {
      containerRef.current?.releasePointerCapture(e.pointerId);
      setIsActive(false);
      // Send final value
      if (pendingValueRef.current !== null) {
        onChange(pendingValueRef.current);
        pendingValueRef.current = null;
      }
    },
    [onChange]
  );

  const fillHeight = (value / 127) * 100;

  return (
    <div
      ref={containerRef}
      className={`
        relative flex flex-col items-center
        touch-none select-none cursor-ns-resize
        ${className}
      `}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerUp}
      role="slider"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={127}
      aria-valuenow={value}
    >
      {/* Track */}
      <div className="flex-1 w-full bg-bg-elevated rounded-lg border border-border-subtle overflow-hidden">
        {/* Fill */}
        <div
          className="absolute bottom-0 left-0 right-0 bg-primary/60 transition-none"
          style={{ height: `${fillHeight}%` }}
        />
        {/* Current position indicator */}
        <div
          className="absolute left-0 right-0 h-1 bg-primary"
          style={{ bottom: `${fillHeight}%`, transform: 'translateY(50%)' }}
        />
      </div>
      {/* Label */}
      <span className="mt-1 text-xs text-text-secondary font-medium">{label}</span>
    </div>
  );
}
