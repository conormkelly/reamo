/**
 * SideRailBankNav Component
 * Compact bank navigation for side rail (landscape-constrained mode)
 *
 * Displays current bank position (e.g., "3/12") with prev/next arrows.
 * Reads state from sideRailSlice which is populated by the active view.
 *
 * @see docs/architecture/RESPONSIVE_FRONTEND_FINAL.md
 */

import { type ReactElement } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useReaperStore } from '../../store';

// =============================================================================
// Component
// =============================================================================

export function SideRailBankNav(): ReactElement | null {
  const bankNav = useReaperStore((s) => s.sideRailBankNav);
  const goBack = useReaperStore((s) => s.sideRailGoBack);
  const goForward = useReaperStore((s) => s.sideRailGoForward);

  // Don't render if no bank nav state from active view
  if (!bankNav) {
    return null;
  }

  const { compactDisplay, bankDisplay, canGoBack, canGoForward } = bankNav;

  return (
    <div className="flex flex-col items-center gap-1 py-2 border-t border-border-subtle">
      {/* Bank display - compact format */}
      <span className="text-[11px] font-medium text-text-secondary tabular-nums">
        {compactDisplay || bankDisplay}
      </span>

      {/* Navigation arrows */}
      <div className="flex items-center gap-0.5">
        <button
          onClick={goBack}
          disabled={!canGoBack}
          className={`
            w-8 h-8 rounded flex items-center justify-center transition-colors
            ${canGoBack
              ? 'text-text-secondary hover:text-text-primary hover:bg-bg-surface/50 active:bg-bg-surface'
              : 'text-text-muted opacity-40'
            }
          `}
          title="Previous bank"
          aria-label="Previous bank"
        >
          <ChevronLeft size={18} />
        </button>
        <button
          onClick={goForward}
          disabled={!canGoForward}
          className={`
            w-8 h-8 rounded flex items-center justify-center transition-colors
            ${canGoForward
              ? 'text-text-secondary hover:text-text-primary hover:bg-bg-surface/50 active:bg-bg-surface'
              : 'text-text-muted opacity-40'
            }
          `}
          title="Next bank"
          aria-label="Next bank"
        >
          <ChevronRight size={18} />
        </button>
      </div>
    </div>
  );
}
