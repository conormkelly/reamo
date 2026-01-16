/**
 * PitchBendWheel Component
 * Vertical touch strip for pitch bend with spring-back to center
 * Rate-limited to 60Hz for smooth pitch bends
 */

import { useState, useCallback, useRef, useEffect, type ReactElement, type PointerEvent } from 'react';

export interface PitchBendWheelProps {
  /** Callback when value changes (0-16383, center=8192) */
  onChange: (value: number) => void;
  /** Label to display */
  label?: string;
  className?: string;
}

/** Center value for pitch bend */
const CENTER_VALUE = 8192;

/** Max pitch bend value */
const MAX_VALUE = 16383;

/** Rate limit in ms (60Hz ≈ 16ms) */
const RATE_LIMIT_MS = 16;

/** Spring-back animation duration in ms */
const SPRING_BACK_MS = 150;

export function PitchBendWheel({
  onChange,
  label = 'BEND',
  className = '',
}: PitchBendWheelProps): ReactElement {
  const [value, setValue] = useState(CENTER_VALUE);
  const [isActive, setIsActive] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastSendRef = useRef<number>(0);
  const pendingValueRef = useRef<number | null>(null);
  const rafRef = useRef<number | null>(null);
  const springAnimRef = useRef<number | null>(null);

  const sendValue = useCallback(
    (newValue: number) => {
      const now = Date.now();
      const timeSinceLastSend = now - lastSendRef.current;

      if (timeSinceLastSend >= RATE_LIMIT_MS) {
        lastSendRef.current = now;
        onChange(newValue);
        pendingValueRef.current = null;
      } else {
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
    if (!containerRef.current) return CENTER_VALUE;
    const rect = containerRef.current.getBoundingClientRect();
    // Center = 0.5, top = 1.0, bottom = 0.0
    const normalized = 1 - (clientY - rect.top) / rect.height;
    // Map to 0-16383 range
    return Math.round(Math.max(0, Math.min(MAX_VALUE, normalized * MAX_VALUE)));
  }, []);

  const springBack = useCallback(() => {
    // Cancel any pending spring animation
    if (springAnimRef.current !== null) {
      cancelAnimationFrame(springAnimRef.current);
    }

    const startValue = value;
    const startTime = Date.now();

    const animate = () => {
      const elapsed = Date.now() - startTime;
      const progress = Math.min(1, elapsed / SPRING_BACK_MS);
      // Ease out cubic
      const eased = 1 - Math.pow(1 - progress, 3);
      const newValue = Math.round(startValue + (CENTER_VALUE - startValue) * eased);

      setValue(newValue);
      sendValue(newValue);

      if (progress < 1) {
        springAnimRef.current = requestAnimationFrame(animate);
      } else {
        springAnimRef.current = null;
      }
    };

    springAnimRef.current = requestAnimationFrame(animate);
  }, [value, sendValue]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (springAnimRef.current !== null) {
        cancelAnimationFrame(springAnimRef.current);
      }
      if (rafRef.current !== null) {
        clearTimeout(rafRef.current);
      }
    };
  }, []);

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      e.stopPropagation();
      // Cancel any spring-back animation
      if (springAnimRef.current !== null) {
        cancelAnimationFrame(springAnimRef.current);
        springAnimRef.current = null;
      }
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
      // Spring back to center
      springBack();
    },
    [springBack]
  );

  // Calculate position as percentage from center (-50% to +50%)
  const positionPercent = ((value / MAX_VALUE) - 0.5) * 100;

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
      aria-valuemax={MAX_VALUE}
      aria-valuenow={value}
    >
      {/* Track */}
      <div className="flex-1 w-full bg-bg-elevated rounded-lg border border-border-subtle overflow-hidden relative">
        {/* Center line */}
        <div className="absolute left-0 right-0 top-1/2 h-px bg-border-subtle" />
        {/* Fill from center */}
        <div
          className="absolute left-0 right-0 bg-primary/40"
          style={{
            top: positionPercent > 0 ? '50%' : `${50 + positionPercent}%`,
            height: `${Math.abs(positionPercent)}%`,
          }}
        />
        {/* Current position indicator */}
        <div
          className={`absolute left-0 right-0 h-1.5 bg-primary rounded-full transition-none ${isActive ? '' : 'transition-all duration-150'}`}
          style={{
            top: `${50 - positionPercent}%`,
            transform: 'translateY(-50%)',
          }}
        />
      </div>
      {/* Label */}
      <span className="mt-1 text-xs text-text-secondary font-medium">{label}</span>
    </div>
  );
}
