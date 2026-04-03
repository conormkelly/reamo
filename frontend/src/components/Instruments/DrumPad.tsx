/**
 * DrumPad Component
 * Individual drum pad with optimized touch event handling and visual feedback
 *
 * iOS Safari Fix: Uses native Touch Events instead of Pointer Events on iOS.
 * Safari's gesture recognition drops ~25% of rapid alternating touches when using
 * Pointer Events. Touch Events fire immediately and bypass gesture detection.
 *
 * Key workarounds applied:
 * - touchstart with {passive: false} + preventDefault() to bypass double-tap detection
 * - touchmove with preventDefault() to prevent Scribble/gesture swallowing (iPadOS 14+)
 * - Track touches by touch.identifier for correct multi-touch handling
 *
 * @see WebKit Bug #211521, Apple Developer Forums threads 125073, 717286, 662874
 */

import { useState, useCallback, useRef, useEffect, type ReactElement, type PointerEvent } from 'react';
import { isIOS } from '../../utils';

export interface DrumPadProps {
  /** MIDI note number (0-127) */
  note: number;
  /** Display label for the pad */
  label: string;
  /** Callback when note is triggered */
  onNoteOn: (note: number, velocity: number) => void;
  /** Callback when note is released */
  onNoteOff: (note: number) => void;
  /** Optional custom background color */
  color?: string;
  className?: string;
}

/** Default velocity for MVP (0-127) */
const DEFAULT_VELOCITY = 100;

/** Minimum ms between triggers to debounce (per-pad) */
const DEBOUNCE_MS = 10;

// Debug logging for touch issues - enable via: window.__debugTouch = true
const DEBUG_TOUCH = typeof window !== 'undefined' &&
  (window as unknown as { __debugTouch?: boolean }).__debugTouch === true;

// Track global event timing for debugging
let globalEventCounter = 0;

export function DrumPad({
  note,
  label,
  onNoteOn,
  onNoteOff,
  color,
  className = '',
}: DrumPadProps): ReactElement {
  const [isActive, setIsActive] = useState(false);
  const buttonRef = useRef<HTMLButtonElement>(null);

  // Track last trigger time to debounce - use performance.now() for precision
  // (Date.now() can be reduced to 100ms precision on Safari for privacy)
  const lastTriggerRef = useRef<number>(0);

  // Track active touch identifiers to prevent duplicate triggers
  const activeTouchesRef = useRef<Set<number>>(new Set());

  // Stable refs for callbacks (avoid recreating listeners)
  const onNoteOnRef = useRef(onNoteOn);
  const onNoteOffRef = useRef(onNoteOff);
  const labelRef = useRef(label);
  const noteRef = useRef(note);

  useEffect(() => {
    onNoteOnRef.current = onNoteOn;
    onNoteOffRef.current = onNoteOff;
    labelRef.current = label;
    noteRef.current = note;
  }, [onNoteOn, onNoteOff, label, note]);

  // Core trigger logic - shared between Touch and Pointer events
  const triggerNote = useCallback((eventType: string) => {
    const eventTime = performance.now();
    const eventId = ++globalEventCounter;
    const timeSinceLast = eventTime - lastTriggerRef.current;

    if (timeSinceLast < DEBOUNCE_MS) {
      if (DEBUG_TOUCH) {
        console.log(
          `[DrumPad ${labelRef.current}] #${eventId} BLOCKED @ ${eventTime.toFixed(1)}ms | ` +
          `delta=${timeSinceLast.toFixed(1)}ms (debounce=${DEBOUNCE_MS}ms)`
        );
      }
      return;
    }

    if (DEBUG_TOUCH) {
      console.log(
        `[DrumPad ${labelRef.current}] #${eventId} TRIGGERED @ ${eventTime.toFixed(1)}ms | ` +
        `type=${eventType}, delta=${timeSinceLast.toFixed(1)}ms`
      );
    }

    lastTriggerRef.current = eventTime;

    // Send MIDI first, then update visual state (prioritize responsiveness)
    const preSendTime = performance.now();
    onNoteOnRef.current(noteRef.current, DEFAULT_VELOCITY);
    const postSendTime = performance.now();

    if (DEBUG_TOUCH) {
      console.log(
        `[DrumPad ${labelRef.current}] #${eventId} SENT @ ${postSendTime.toFixed(1)}ms | ` +
        `sendLatency=${(postSendTime - preSendTime).toFixed(2)}ms, ` +
        `totalLatency=${(postSendTime - eventTime).toFixed(2)}ms`
      );
    }

    setIsActive(true);
  }, []);

  // iOS: Use native Touch Events with {passive: false}
  // This bypasses Safari's gesture recognition that drops rapid touches
  useEffect(() => {
    if (!isIOS) return;

    const button = buttonRef.current;
    if (!button) return;

    const handleTouchStart = (e: TouchEvent) => {
      e.preventDefault(); // Critical: prevents double-tap zoom detection

      for (const touch of Array.from(e.changedTouches)) {
        // Only trigger if this touch identifier hasn't been seen
        if (!activeTouchesRef.current.has(touch.identifier)) {
          activeTouchesRef.current.add(touch.identifier);
          triggerNote(`touch:${touch.identifier}`);
        }
      }
    };

    const handleTouchEnd = (e: TouchEvent) => {
      for (const touch of Array.from(e.changedTouches)) {
        activeTouchesRef.current.delete(touch.identifier);
      }
      onNoteOffRef.current(noteRef.current);
      if (activeTouchesRef.current.size === 0) {
        setIsActive(false);
      }
    };

    // Critical: touchmove with preventDefault prevents iPadOS Scribble from swallowing events
    // Also prevents any gesture recognition interference
    const handleTouchMove = (e: TouchEvent) => {
      e.preventDefault();
    };

    // Add listeners with {passive: false} - React synthetic events don't support this
    button.addEventListener('touchstart', handleTouchStart, { passive: false });
    button.addEventListener('touchend', handleTouchEnd, { passive: false });
    button.addEventListener('touchcancel', handleTouchEnd, { passive: false });
    button.addEventListener('touchmove', handleTouchMove, { passive: false });

    return () => {
      button.removeEventListener('touchstart', handleTouchStart);
      button.removeEventListener('touchend', handleTouchEnd);
      button.removeEventListener('touchcancel', handleTouchEnd);
      button.removeEventListener('touchmove', handleTouchMove);
    };
  }, [triggerNote]);

  // Non-iOS: Use Pointer Events (more reliable on Android/desktop)
  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      if (isIOS) return; // Touch Events handle iOS

      e.preventDefault();
      e.stopPropagation();
      triggerNote(`pointer:${e.pointerType}`);
    },
    [triggerNote]
  );

  const handlePointerUp = useCallback(() => {
    if (isIOS) return;
    onNoteOffRef.current(noteRef.current);
    setIsActive(false);
  }, []);

  return (
    <button
      ref={buttonRef}
      type="button"
      className={`
        relative flex items-center justify-center
        rounded-lg border-2 border-border-subtle
        text-text-primary font-medium text-sm
        select-none touch-none
        transition-transform duration-75
        ${isActive ? 'scale-95 brightness-125' : 'hover:brightness-110'}
        ${className}
      `}
      style={{
        backgroundColor: color || 'var(--color-bg-elevated)',
        borderColor: isActive ? 'var(--color-primary)' : undefined,
        // Additional iOS touch optimizations
        WebkitTouchCallout: 'none',
        WebkitUserSelect: 'none',
        WebkitTapHighlightColor: 'transparent',
      }}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerUp}
      onPointerLeave={handlePointerUp}
      onContextMenu={(e) => e.preventDefault()}
      aria-label={`${label} (MIDI note ${note})`}
    >
      <span className="truncate px-1">{label}</span>
    </button>
  );
}
