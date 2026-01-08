/**
 * ClockElementWrapper - Edit mode wrapper for clock elements
 * Shows drag handle, visibility toggle, and size controls when in edit mode
 * Supports both HTML5 drag-and-drop (desktop) and touch events (iOS/mobile)
 */

import { useRef, useCallback, type ReactElement, type ReactNode } from 'react';
import { GripVertical, Eye, EyeOff, Minus, Plus, ALargeSmall } from 'lucide-react';
import type { ClockElement, ScaleKey } from '../../../store';

interface ClockElementWrapperProps {
  id: ClockElement;
  label: string;
  visible: boolean;
  scale: number;
  scaleKey: ScaleKey | null; // null for elements without scale (recording indicator)
  editMode: boolean;
  index: number;
  isDragTarget: boolean;
  onToggleVisible: () => void;
  onScaleChange: (scale: number) => void;
  onDragStart: () => void;
  onDragOver: () => void;
  onDragEnd: () => void;
  children: ReactNode;
}

export function ClockElementWrapper({
  id,
  label,
  visible,
  scale,
  scaleKey,
  editMode,
  index,
  isDragTarget,
  onToggleVisible,
  onScaleChange,
  onDragStart,
  onDragOver,
  onDragEnd,
  children,
}: ClockElementWrapperProps): ReactElement | null {
  // Always render wrapper but hide content if not visible (in non-edit mode)
  // In edit mode, show everything so user can toggle visibility back on
  if (!editMode && !visible) {
    return null;
  }

  const canDecrease = scale > 0.5;
  const canIncrease = scale < 2.0;
  const step = 0.1;

  // Touch drag support for iOS
  const isDraggingRef = useRef(false);

  const handleTouchStart = useCallback(
    (e: React.TouchEvent) => {
      if (!editMode) return;
      e.preventDefault(); // Prevent scroll while dragging
      isDraggingRef.current = true;
      onDragStart();
    },
    [editMode, onDragStart]
  );

  const handleTouchMove = useCallback(
    (e: React.TouchEvent) => {
      if (!isDraggingRef.current) return;
      e.preventDefault();

      const touch = e.touches[0];
      const touchY = touch.clientY;

      // Find all clock elements and check which one the touch is over
      const allElements = document.querySelectorAll('[data-clock-element]');
      for (const el of allElements) {
        const rect = el.getBoundingClientRect();
        // Check if touch Y is within this element's vertical bounds
        if (touchY >= rect.top && touchY <= rect.bottom) {
          const targetIndex = parseInt(el.getAttribute('data-index') || '-1', 10);
          if (targetIndex >= 0 && targetIndex !== index) {
            // Dispatch custom event to notify parent of drag target
            window.dispatchEvent(
              new CustomEvent('clock-drag-over', { detail: { targetIndex } })
            );
          }
          break;
        }
      }
    },
    [index]
  );

  const handleTouchEnd = useCallback(() => {
    if (!isDraggingRef.current) return;
    isDraggingRef.current = false;
    onDragEnd();
  }, [onDragEnd]);

  return (
    <div
      data-clock-element={id}
      data-index={index}
      className={`
        relative
        ${editMode ? 'p-2' : ''}
        ${isDragTarget ? 'ring-2 ring-blue-500 ring-offset-2 ring-offset-black rounded-lg' : ''}
        ${editMode && !visible ? 'opacity-40' : ''}
      `}
      draggable={editMode}
      onDragStart={(e) => {
        e.dataTransfer.effectAllowed = 'move';
        onDragStart();
      }}
      onDragOver={(e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        onDragOver();
      }}
      onDragEnd={onDragEnd}
      onDrop={(e) => {
        e.preventDefault();
        onDragEnd();
      }}
    >
      {editMode && (
        <div className="flex items-center justify-between mb-2">
          {/* Left side: drag handle + label */}
          <div className="flex items-center gap-2">
            <div
              className="cursor-grab active:cursor-grabbing text-gray-500 hover:text-gray-300 touch-none p-2 -m-2"
              onTouchStart={handleTouchStart}
              onTouchMove={handleTouchMove}
              onTouchEnd={handleTouchEnd}
              onTouchCancel={handleTouchEnd}
            >
              <GripVertical size={24} />
            </div>
            <span className="text-xs text-gray-400 uppercase tracking-wide">{label}</span>
          </div>

          {/* Right side: visibility toggle */}
          <button
            onClick={onToggleVisible}
            className={`p-1.5 rounded transition-colors ${
              visible
                ? 'text-gray-300 hover:text-white hover:bg-gray-700'
                : 'text-gray-600 hover:text-gray-400 hover:bg-gray-800'
            }`}
            title={visible ? 'Hide element' : 'Show element'}
          >
            {visible ? <Eye size={18} /> : <EyeOff size={18} />}
          </button>
        </div>
      )}

      {/* Element content - render even if hidden in edit mode */}
      <div className={editMode && !visible ? 'pointer-events-none' : ''}>
        {children}
      </div>

      {/* Size controls - only show in edit mode for elements with scale */}
      {editMode && scaleKey && (
        <div className="flex justify-center mt-2">
          <div className="inline-flex items-center gap-0.5 bg-gray-800/80 rounded-lg p-0.5">
            <button
              onClick={() => onScaleChange(Math.max(0.5, scale - step))}
              disabled={!canDecrease}
              className={`p-1.5 rounded transition-colors ${
                canDecrease
                  ? 'hover:bg-gray-700 text-gray-300'
                  : 'text-gray-600 cursor-not-allowed'
              }`}
              title="Decrease size"
              aria-label="Decrease size"
            >
              <Minus size={14} />
            </button>
            <div
              className="px-2 text-gray-400 text-xs font-mono min-w-[3rem] text-center"
              title={`Scale: ${Math.round(scale * 100)}%`}
            >
              <ALargeSmall size={16} className="inline mr-1" />
              {Math.round(scale * 100)}%
            </div>
            <button
              onClick={() => onScaleChange(Math.min(2.0, scale + step))}
              disabled={!canIncrease}
              className={`p-1.5 rounded transition-colors ${
                canIncrease
                  ? 'hover:bg-gray-700 text-gray-300'
                  : 'text-gray-600 cursor-not-allowed'
              }`}
              title="Increase size"
              aria-label="Increase size"
            >
              <Plus size={14} />
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
