/**
 * useListReorder - Reusable hook for drag-and-drop list reordering
 *
 * Extracts the pattern used in ActionsSection for consistent drag behavior:
 * - Manages drag state (source index, target index)
 * - Provides handlers for HTML5 drag events
 * - Returns computed values for styling (isDragging, isDragTarget)
 * - Calls onReorder when drag completes with different indices
 */

import { useState, useCallback, useMemo } from 'react';

export interface UseListReorderOptions {
  /** Callback when reorder completes */
  onReorder: (fromIndex: number, toIndex: number) => void;
  /** Whether drag is enabled (e.g., edit mode) */
  enabled?: boolean;
}

export interface UseListReorderReturn {
  /** Index of item being dragged (null if not dragging) */
  dragFromIndex: number | null;
  /** Index of current drop target (null if not over any target) */
  dragOverIndex: number | null;
  /** Check if item at index is being dragged */
  isDragging: (index: number) => boolean;
  /** Check if item at index is a valid drop target */
  isDragTarget: (index: number) => boolean;
  /** Get props to spread on draggable item */
  getDragItemProps: (index: number) => {
    draggable: boolean;
    onDragStart: (e: React.DragEvent) => void;
    onDragOver: (e: React.DragEvent) => void;
    onDrop: (e: React.DragEvent) => void;
    onDragEnd: () => void;
    onTouchStart: (e: React.TouchEvent) => void;
    onTouchMove: (e: React.TouchEvent) => void;
    onTouchEnd: () => void;
  };
}

export function useListReorder({
  onReorder,
  enabled = true,
}: UseListReorderOptions): UseListReorderReturn {
  const [dragFromIndex, setDragFromIndex] = useState<number | null>(null);
  const [dragOverIndex, setDragOverIndex] = useState<number | null>(null);

  // Touch tracking refs (using state to avoid stale closures)
  const [touchStartY, setTouchStartY] = useState(0);
  const [touchItemHeight, setTouchItemHeight] = useState(60);

  const handleDragStart = useCallback(
    (index: number) => (e: React.DragEvent) => {
      if (!enabled) return;
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', String(index));

      // Create custom drag image that preserves the element's appearance
      // This avoids capturing elements underneath (e.g., in modals with transparent backdrop)
      const target = e.currentTarget as HTMLElement;
      const clone = target.cloneNode(true) as HTMLElement;
      const computed = getComputedStyle(target);

      // Position off-screen for capture
      clone.style.position = 'fixed';
      clone.style.top = '-9999px';
      clone.style.left = '-9999px';

      // Preserve original dimensions and appearance
      clone.style.width = `${target.offsetWidth}px`;
      clone.style.height = `${target.offsetHeight}px`;
      clone.style.backgroundColor = computed.backgroundColor;
      clone.style.borderRadius = computed.borderRadius;
      clone.style.opacity = '1';

      // Remove any transform/ring classes that might affect appearance
      clone.classList.remove('scale-105', 'ring-2', 'opacity-50');

      document.body.appendChild(clone);

      // Set custom drag image centered on cursor
      const rect = target.getBoundingClientRect();
      const offsetX = e.clientX - rect.left;
      const offsetY = e.clientY - rect.top;
      e.dataTransfer.setDragImage(clone, offsetX, offsetY);

      // Clean up clone after browser captures it
      requestAnimationFrame(() => {
        document.body.removeChild(clone);
      });

      setDragFromIndex(index);
    },
    [enabled]
  );

  const handleDragOver = useCallback(
    (index: number) => (e: React.DragEvent) => {
      if (!enabled) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      setDragOverIndex(index);
    },
    [enabled]
  );

  // Handle drop on target - this is where reorder actually happens
  const handleDrop = useCallback(
    (index: number) => (e: React.DragEvent) => {
      if (!enabled) return;
      e.preventDefault();

      if (dragFromIndex !== null && dragFromIndex !== index) {
        onReorder(dragFromIndex, index);
      }
    },
    [enabled, dragFromIndex, onReorder]
  );

  const handleDragEnd = useCallback(() => {
    // Cleanup state after drag completes (or is cancelled)
    setDragFromIndex(null);
    setDragOverIndex(null);
  }, []);

  // Touch handlers for mobile
  const handleTouchStart = useCallback(
    (index: number) => (e: React.TouchEvent) => {
      if (!enabled) return;
      const touch = e.touches[0];
      setTouchStartY(touch.clientY);
      setDragFromIndex(index);

      // Estimate item height from the touched element
      const target = e.currentTarget as HTMLElement;
      if (target) {
        setTouchItemHeight(target.offsetHeight + 8); // Include gap
      }
    },
    [enabled]
  );

  const handleTouchMove = useCallback(
    (e: React.TouchEvent) => {
      if (!enabled || dragFromIndex === null) return;

      const touch = e.touches[0];
      const deltaY = touch.clientY - touchStartY;
      const itemsMoved = Math.round(deltaY / touchItemHeight);

      // Calculate target index, clamping handled by consumer
      const newIndex = dragFromIndex + itemsMoved;
      setDragOverIndex(newIndex);
    },
    [enabled, dragFromIndex, touchStartY, touchItemHeight]
  );

  const handleTouchEnd = useCallback(() => {
    if (
      dragFromIndex !== null &&
      dragOverIndex !== null &&
      dragFromIndex !== dragOverIndex
    ) {
      onReorder(dragFromIndex, dragOverIndex);
    }
    setDragFromIndex(null);
    setDragOverIndex(null);
  }, [dragFromIndex, dragOverIndex, onReorder]);

  const isDragging = useCallback(
    (index: number) => dragFromIndex === index,
    [dragFromIndex]
  );

  const isDragTarget = useCallback(
    (index: number) =>
      dragOverIndex === index &&
      dragFromIndex !== null &&
      dragFromIndex !== index,
    [dragFromIndex, dragOverIndex]
  );

  const getDragItemProps = useCallback(
    (index: number) => ({
      draggable: enabled,
      onDragStart: handleDragStart(index),
      onDragOver: handleDragOver(index),
      onDrop: handleDrop(index),
      onDragEnd: handleDragEnd,
      onTouchStart: handleTouchStart(index),
      onTouchMove: handleTouchMove,
      onTouchEnd: handleTouchEnd,
    }),
    [enabled, handleDragStart, handleDragOver, handleDrop, handleDragEnd, handleTouchStart, handleTouchMove, handleTouchEnd]
  );

  return useMemo(
    () => ({
      dragFromIndex,
      dragOverIndex,
      isDragging,
      isDragTarget,
      getDragItemProps,
    }),
    [dragFromIndex, dragOverIndex, isDragging, isDragTarget, getDragItemProps]
  );
}
