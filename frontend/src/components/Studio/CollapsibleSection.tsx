/**
 * CollapsibleSection Component
 * Reusable wrapper for collapsible sections in Studio view
 * Supports lock mode
 */

import type { ReactElement, ReactNode } from 'react';
import { ChevronDown, ChevronRight } from 'lucide-react';
import type { SectionId } from '../../store';

export interface CollapsibleSectionProps {
  id: SectionId;
  title: string;
  collapsed: boolean;
  onToggle: () => void;
  headerControls?: ReactNode; // Optional controls shown when expanded on right side (e.g., TimelineModeToggle)
  children: ReactNode;
}

export function CollapsibleSection({
  id: _id, // Reserved for future use (e.g., aria-labelledby)
  title,
  collapsed,
  onToggle,
  headerControls,
  children,
}: CollapsibleSectionProps): ReactElement {
  return (
    <section className="mb-4">
      {/* Section header */}
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center gap-1">
          {/* Collapse toggle */}
          <button
            data-section-header={_id}
            onClick={onToggle}
            className="flex items-center gap-1 text-sm font-medium text-text-secondary hover:text-text-tertiary transition-colors"
          >
            {collapsed ? <ChevronRight size={16} /> : <ChevronDown size={16} />}
            <h3>{title}</h3>
          </button>
        </div>

        {/* Header controls (e.g., TimelineModeToggle) - shown on right when expanded */}
        {!collapsed && headerControls}
      </div>

      {/* Section content - only rendered when not collapsed */}
      {!collapsed && children}
    </section>
  );
}
