/**
 * OrientationHint - Soft orientation suggestion banner
 *
 * A dismissible banner that suggests (but does not enforce) a preferred
 * orientation for better experience. Used primarily in Instruments view.
 *
 * This is a NON-BLOCKING alternative to hard orientation locks which:
 * - Don't work on iOS Safari (screen.orientation.lock() unsupported)
 * - Violate WCAG 1.3.4 accessibility guidelines
 * - Frustrate users who prefer working in their chosen orientation
 *
 * @see docs/architecture/UX_GUIDELINES.md §9 (Instruments Orientation Strategy)
 */

import { useState } from 'react';
import { X, RotateCcw } from 'lucide-react';

export type PreferredOrientation = 'landscape' | 'portrait';

export interface OrientationHintProps {
  /** The preferred orientation for best experience */
  preferred: PreferredOrientation;
  /** Additional className for positioning */
  className?: string;
}

/**
 * Dismissible orientation hint banner
 *
 * @example
 * const isLandscape = useIsLandscape();
 * const showHint = instrument === 'piano' && !isLandscape;
 *
 * {showHint && (
 *   <OrientationHint
 *     preferred="landscape"
 *     className="absolute top-2 inset-x-4 z-elevated"
 *   />
 * )}
 */
export function OrientationHint({ preferred, className = '' }: OrientationHintProps) {
  const [dismissed, setDismissed] = useState(false);

  if (dismissed) return null;

  const message = preferred === 'landscape'
    ? 'Rotate to landscape for the best experience'
    : 'Rotate to portrait for the best experience';

  return (
    <div
      className={`
        flex items-center justify-between gap-2 px-3 py-2
        bg-bg-surface/90 backdrop-blur-sm rounded-lg border border-border-subtle
        text-sm text-text-secondary
        ${className}
      `}
      role="status"
      aria-live="polite"
    >
      <div className="flex items-center gap-2">
        <RotateCcw className="w-4 h-4 shrink-0" aria-hidden="true" />
        <span>{message}</span>
      </div>
      <button
        onClick={() => setDismissed(true)}
        className="p-1 hover:bg-bg-hover rounded shrink-0"
        aria-label="Dismiss orientation hint"
      >
        <X className="w-4 h-4" />
      </button>
    </div>
  );
}
