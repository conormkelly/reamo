/**
 * SideRailActions Component
 * Quick access to view-specific actions in side rail mode
 *
 * Provides an Info button that opens a BottomSheet with the view's
 * secondary panel content (TrackInfoBar for Mixer, Info/Toolbar for Timeline).
 *
 * Reads info content from sideRailSlice which is populated by the active view.
 *
 * @see docs/architecture/RESPONSIVE_FRONTEND_FINAL.md
 */

import { useState, type ReactElement } from 'react';
import { Info } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaperStore } from '../../store';

// =============================================================================
// Component
// =============================================================================

export function SideRailActions(): ReactElement | null {
  const [isInfoOpen, setIsInfoOpen] = useState(false);
  const sideRailInfo = useReaperStore((s) => s.sideRailInfo);

  // Don't render if no info content provided by active view
  if (!sideRailInfo) {
    return null;
  }

  const { content, label } = sideRailInfo;

  return (
    <>
      <div className="flex flex-col items-center py-2 border-t border-border-subtle">
        <button
          onClick={() => setIsInfoOpen(true)}
          className="w-11 h-11 rounded-lg flex items-center justify-center text-text-secondary hover:text-text-primary hover:bg-bg-surface/50 active:bg-bg-surface transition-colors"
          title={label}
          aria-label={label}
        >
          <Info size={20} />
        </button>
      </div>

      {/* Info BottomSheet */}
      <BottomSheet
        isOpen={isInfoOpen}
        onClose={() => setIsInfoOpen(false)}
        ariaLabel={label}
      >
        <div className="px-4 pb-4 max-h-[70vh] overflow-y-auto">
          {content}
        </div>
      </BottomSheet>
    </>
  );
}
