/**
 * ReorderSectionsModal Component
 * Modal for reordering sections and customizing their appearance
 */

import { useState, useRef, type ReactElement } from 'react';
import { X, GripVertical } from 'lucide-react';
import { useReaperStore, type SectionId } from '../../store';

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
  const { sections, reorderSections } = useReaperStore();

  // Build ordered list of section IDs
  const [orderedSections, setOrderedSections] = useState<SectionId[]>(() => {
    const ids: SectionId[] = ['project', 'toolbar', 'timeline', 'mixer'];
    return ids.sort((a, b) => sections[a].order - sections[b].order);
  });

  const [draggedIndex, setDraggedIndex] = useState<number | null>(null);
  const [dragOverIndex, setDragOverIndex] = useState<number | null>(null);
  const touchStartY = useRef<number>(0);
  const touchCurrentY = useRef<number>(0);

  if (!isOpen) return null;

  // Desktop drag handlers
  const handleDragStart = (index: number) => {
    setDraggedIndex(index);
  };

  const handleDragOver = (e: React.DragEvent, index: number) => {
    e.preventDefault();
    setDragOverIndex(index);
  };

  const handleDrop = (index: number) => {
    if (draggedIndex === null || draggedIndex === index) {
      setDraggedIndex(null);
      setDragOverIndex(null);
      return;
    }

    // Reorder locally
    const newOrder = [...orderedSections];
    const [moved] = newOrder.splice(draggedIndex, 1);
    newOrder.splice(index, 0, moved);
    setOrderedSections(newOrder);

    // Update store
    reorderSections(draggedIndex, index);

    setDraggedIndex(null);
    setDragOverIndex(null);
  };

  const handleDragEnd = () => {
    setDraggedIndex(null);
    setDragOverIndex(null);
  };

  // Touch handlers for mobile
  const handleTouchStart = (e: React.TouchEvent, index: number) => {
    touchStartY.current = e.touches[0].clientY;
    touchCurrentY.current = e.touches[0].clientY;
    setDraggedIndex(index);
  };

  const handleTouchMove = (e: React.TouchEvent) => {
    if (draggedIndex === null) return;

    touchCurrentY.current = e.touches[0].clientY;
    const deltaY = touchCurrentY.current - touchStartY.current;

    // Calculate which item we're over based on touch position
    const itemHeight = 60; // Approximate height of each item
    const itemsMoved = Math.round(deltaY / itemHeight);
    const newIndex = Math.max(0, Math.min(orderedSections.length - 1, draggedIndex + itemsMoved));

    setDragOverIndex(newIndex);
  };

  const handleTouchEnd = () => {
    if (draggedIndex === null || dragOverIndex === null || draggedIndex === dragOverIndex) {
      setDraggedIndex(null);
      setDragOverIndex(null);
      return;
    }

    // Reorder locally
    const newOrder = [...orderedSections];
    const [moved] = newOrder.splice(draggedIndex, 1);
    newOrder.splice(dragOverIndex, 0, moved);
    setOrderedSections(newOrder);

    // Update store
    reorderSections(draggedIndex, dragOverIndex);

    setDraggedIndex(null);
    setDragOverIndex(null);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={onClose}>
      <div
        className="bg-gray-900 rounded-lg shadow-xl border border-gray-700 w-full max-w-md mx-4"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-gray-700">
          <h2 className="text-lg font-medium">Reorder Sections</h2>
          <button
            onClick={onClose}
            className="p-1 hover:bg-gray-800 rounded transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-2">
          {orderedSections.map((sectionId, index) => {
            const isDragging = draggedIndex === index;
            const isOver = dragOverIndex === index && draggedIndex !== index;

            return (
              <div
                key={sectionId}
                data-testid="reorder-section-item"
                draggable
                onDragStart={() => handleDragStart(index)}
                onDragOver={(e) => handleDragOver(e, index)}
                onDrop={() => handleDrop(index)}
                onDragEnd={handleDragEnd}
                onTouchStart={(e) => handleTouchStart(e, index)}
                onTouchMove={handleTouchMove}
                onTouchEnd={handleTouchEnd}
                className={`
                  flex items-center gap-3 p-3 rounded-lg border-2 transition-all cursor-move touch-none select-none
                  ${isDragging ? 'opacity-50 border-blue-500' : 'border-gray-700'}
                  ${isOver ? 'border-blue-400 bg-blue-900/20' : 'bg-gray-800'}
                  hover:bg-gray-750
                `}
              >
                <GripVertical size={20} className="text-gray-500" />
                <span className="flex-1 text-sm font-medium">{SECTION_LABELS[sectionId]}</span>
              </div>
            );
          })}
        </div>

        {/* Footer */}
        <div className="p-4 border-t border-gray-700 flex justify-end">
          <button
            onClick={onClose}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-lg transition-colors text-sm font-medium"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
