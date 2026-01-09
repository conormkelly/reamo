/**
 * ReorderSectionsModal Component
 * Modal for reordering sections using the unified drag pattern from ActionsSection
 */

import { useState, useCallback, type ReactElement } from 'react';
import { X, GripVertical } from 'lucide-react';
import { useReaperStore, type SectionId } from '../../store';
import { useListReorder } from '../../hooks';

export interface ReorderSectionsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const SECTION_LABELS: Record<SectionId, string> = {
  project: 'Project',
  toolbar: 'Toolbar',
  timeline: 'Timeline',
  mixer: 'Mixer',
};

export function ReorderSectionsModal({ isOpen, onClose }: ReorderSectionsModalProps): ReactElement | null {
  const { sections, reorderLayoutSections } = useReaperStore();

  // Build ordered list of section IDs
  const [orderedSections, setOrderedSections] = useState<SectionId[]>(() => {
    const ids: SectionId[] = ['project', 'toolbar', 'timeline', 'mixer'];
    return ids.sort((a, b) => sections[a].order - sections[b].order);
  });

  // Handle reorder - update local state and store
  const handleReorder = useCallback(
    (fromIndex: number, toIndex: number) => {
      // Clamp toIndex to valid range
      const clampedTo = Math.max(0, Math.min(orderedSections.length - 1, toIndex));
      if (fromIndex === clampedTo) return;

      // Reorder locally
      const newOrder = [...orderedSections];
      const [moved] = newOrder.splice(fromIndex, 1);
      newOrder.splice(clampedTo, 0, moved);
      setOrderedSections(newOrder);

      // Update store
      reorderLayoutSections(fromIndex, clampedTo);
    },
    [orderedSections, reorderLayoutSections]
  );

  // Use unified drag hook
  const { isDragging, isDragTarget, getDragItemProps } = useListReorder({
    onReorder: handleReorder,
    enabled: true,
  });

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={onClose}>
      <div
        className="bg-bg-deep rounded-lg shadow-xl border border-border-subtle w-full max-w-md mx-4"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-border-subtle">
          <h2 className="text-lg font-medium">Reorder Sections</h2>
          <button
            onClick={onClose}
            className="p-1 hover:bg-bg-surface rounded transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-2">
          {orderedSections.map((sectionId, index) => (
            <div
              key={sectionId}
              data-testid="reorder-section-item"
              {...getDragItemProps(index)}
              className={`
                flex items-center gap-3 p-3 rounded-lg transition-all cursor-grab active:cursor-grabbing touch-none select-none
                bg-bg-deep ring-1 ring-edit-mode-ring
                ${isDragging(index) ? 'opacity-50' : ''}
                ${isDragTarget(index) ? 'ring-2 ring-drag-target-ring scale-[1.02]' : ''}
                hover:bg-bg-elevated
              `}
            >
              <GripVertical size={20} className="text-text-muted" />
              <span className="flex-1 text-sm font-medium">{SECTION_LABELS[sectionId]}</span>
            </div>
          ))}
        </div>

        {/* Footer */}
        <div className="p-4 border-t border-border-subtle flex justify-end">
          <button
            onClick={onClose}
            className="px-4 py-2 bg-primary hover:bg-primary-active rounded-lg transition-colors text-sm font-medium"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
