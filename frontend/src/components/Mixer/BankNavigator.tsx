/**
 * BankNavigator Component
 * Navigation controls for mixer bank paging.
 * Shows current bank position and prev/next buttons.
 */

import type { ReactElement } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';

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
  className = '',
}: BankNavigatorProps): ReactElement {
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

      {/* Bank display */}
      <span className="text-sm font-mono text-text-secondary min-w-[80px] text-center">
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
