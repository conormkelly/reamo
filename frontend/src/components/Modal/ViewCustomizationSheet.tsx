/**
 * ViewCustomizationSheet - Bottom sheet for showing/hiding and reordering views
 *
 * Per-view Eye/EyeOff toggles + drag-to-reorder. Prevents hiding the last visible view.
 */

import { Eye, EyeOff, GripVertical } from 'lucide-react';
import { BottomSheet } from './BottomSheet';
import { useReaperStore } from '../../store';
import { viewMeta, VIEW_ORDER } from '../../viewRegistry';
import { useListReorder } from '../../hooks/useListReorder';

export interface ViewCustomizationSheetProps {
  isOpen: boolean;
  onClose: () => void;
}

export function ViewCustomizationSheet({ isOpen, onClose }: ViewCustomizationSheetProps) {
  const hiddenViews = useReaperStore((s) => s.hiddenViews);
  const viewOrder = useReaperStore((s) => s.viewOrder);
  const toggleViewVisibility = useReaperStore((s) => s.toggleViewVisibility);
  const reorderView = useReaperStore((s) => s.reorderView);

  const visibleCount = VIEW_ORDER.length - hiddenViews.length;

  const { getDragItemProps, isDragging, isDragTarget } = useListReorder({
    onReorder: reorderView,
    enabled: true,
  });

  return (
    <BottomSheet isOpen={isOpen} onClose={onClose} ariaLabel="Customize views">
      <div className="px-sheet-x pb-sheet-bottom">
        <h2 className="text-lg font-semibold text-text-primary mb-4">Customize Views</h2>

        <div className="space-y-1">
          {viewOrder.map((viewId, index) => {
            const meta = viewMeta[viewId];
            const isVisible = !hiddenViews.includes(viewId);
            const isLastVisible = isVisible && visibleCount <= 1;

            return (
              <div
                key={viewId}
                {...getDragItemProps(index)}
                className={`flex items-center gap-2 px-2 py-3 rounded-lg transition-all ${
                  isDragging(index) ? 'opacity-40' : ''
                } ${isDragTarget(index) ? 'ring-2 ring-primary' : ''}`}
              >
                {/* Drag handle */}
                <div className="cursor-grab active:cursor-grabbing text-text-muted touch-none">
                  <GripVertical size={18} />
                </div>

                {/* View name */}
                <span className="flex-1 text-sm text-text-primary">{meta.label}</span>

                {/* Visibility toggle */}
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    if (!isLastVisible) toggleViewVisibility(viewId);
                  }}
                  disabled={isLastVisible}
                  className={`flex items-center gap-1.5 px-2 py-1 rounded text-xs transition-colors ${
                    isLastVisible
                      ? 'opacity-40 cursor-not-allowed'
                      : 'hover:bg-bg-elevated/50 active:bg-bg-elevated'
                  } ${isVisible ? 'text-success' : 'text-text-muted'}`}
                >
                  {isVisible ? <Eye size={16} /> : <EyeOff size={16} />}
                  {isVisible ? 'Visible' : 'Hidden'}
                </button>
              </div>
            );
          })}
        </div>
      </div>
    </BottomSheet>
  );
}
