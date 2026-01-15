/**
 * BankNavigator Component
 * Navigation controls for mixer bank paging.
 * Shows current bank position and prev/next buttons.
 *
 * Hold the bank display to trigger onHoldStart/onHoldEnd callbacks
 * (used in Timeline view to show track labels overlay).
 */

import { useRef, useCallback, type ReactElement } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';

/** Delay before hold is activated (ms) */
const HOLD_DELAY = 300;

export interface BankNavigatorProps {
  /** Display string (e.g., "1-8 of 24") */
  bankDisplay: string;
  /** Can navigate backwards */
  canGoBack: boolean;
  /** Can navigate forwards */
  canGoForward: boolean;
  /** Navigate to previous bank */
  onBack: () => void;
  /** Navigate to next bank */
  onForward: () => void;
  /** Called when user starts holding the bank display */
  onHoldStart?: () => void;
  /** Called when user releases the bank display */
  onHoldEnd?: () => void;
  className?: string;
}

/**
 * Bank navigation controls for the mixer.
 *
 * Shows the current bank range and total tracks,
 * with prev/next buttons for bank navigation.
 */
export function BankNavigator({
  bankDisplay,
  canGoBack,
  canGoForward,
  onBack,
  onForward,
  onHoldStart,
  onHoldEnd,
  className = '',
}: BankNavigatorProps): ReactElement {
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isHoldingRef = useRef(false);

  const handlePointerDown = useCallback(() => {
    if (!onHoldStart) return;

    holdTimerRef.current = setTimeout(() => {
      isHoldingRef.current = true;
      onHoldStart();
    }, HOLD_DELAY);
  }, [onHoldStart]);

  const handlePointerUp = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    if (isHoldingRef.current) {
      isHoldingRef.current = false;
      onHoldEnd?.();
    }
  }, [onHoldEnd]);

  return (
    <div className={`flex items-center gap-2 ${className}`}>
      {/* Previous bank button */}
      <button
        onClick={onBack}
        disabled={!canGoBack}
        className={`p-2 rounded-lg transition-colors ${
          canGoBack
            ? 'bg-bg-elevated hover:bg-bg-hover text-text-primary'
            : 'bg-bg-surface text-text-disabled cursor-not-allowed'
        }`}
        title="Previous bank"
        aria-label="Previous bank"
      >
        <ChevronLeft size={20} />
      </button>

      {/* Bank display - hold to show track labels overlay */}
      <span
        className={`text-sm font-mono text-text-secondary min-w-[80px] text-center select-none ${
          onHoldStart ? 'cursor-pointer active:text-text-primary' : ''
        }`}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
        onPointerLeave={handlePointerUp}
      >
        {bankDisplay}
      </span>

      {/* Next bank button */}
      <button
        onClick={onForward}
        disabled={!canGoForward}
        className={`p-2 rounded-lg transition-colors ${
          canGoForward
            ? 'bg-bg-elevated hover:bg-bg-hover text-text-primary'
            : 'bg-bg-surface text-text-disabled cursor-not-allowed'
        }`}
        title="Next bank"
        aria-label="Next bank"
      >
        <ChevronRight size={20} />
      </button>
    </div>
  );
}
