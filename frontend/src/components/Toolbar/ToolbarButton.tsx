/**
 * ToolbarButton - Individual action button with toggle state support
 */

import { useCallback, useRef } from 'react';
import { Pencil } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { action as actionCmd, midi as midiCmd } from '../../core/WebSocketCommands';
import type { ToolbarAction, ToggleState } from '../../store/slices/toolbarSlice';
import { DynamicIcon } from './DynamicIcon';

// Size variants for buttons (used by ActionsGrid)
type ButtonSize = 'xs' | 'sm' | 'md' | 'lg';

// Layout modes for responsive toolbar
export type ToolbarLayout = 'horizontal' | 'vertical' | 'grid';

// Drag props from useListReorder hook
interface DragItemProps {
  draggable: boolean;
  onDragStart: (e: React.DragEvent) => void;
  onDragOver: (e: React.DragEvent) => void;
  onDrop: (e: React.DragEvent) => void;
  onDragEnd: () => void;
  onTouchStart: (e: React.TouchEvent) => void;
  onTouchMove: (e: React.TouchEvent) => void;
  onTouchEnd: () => void;
}

/** Long-press delay to enter edit mode (ms) */
const LONG_PRESS_DELAY = 300;

interface ToolbarButtonProps {
  action: ToolbarAction;
  toggleState?: ToggleState;
  editMode: boolean;
  onEdit: () => void;
  /** Called on long-press (enters edit mode) */
  onLongPress?: () => void;
  /** Layout mode - determines sizing strategy */
  layout?: ToolbarLayout;
  /** Optional size - only used when layout='grid' */
  size?: ButtonSize;
  // Drag and drop via useListReorder hook (preferred)
  dragProps?: DragItemProps;
  isDragTarget?: boolean;
}

// Size configurations (used when layout='grid' with size prop)
const SIZE_CONFIG = {
  xs: { button: 'min-w-[32px] h-[32px] px-1.5 py-1', icon: 14, text: 'text-[9px]' },
  sm: { button: 'min-w-[48px] h-[48px] px-2 py-1.5', icon: 18, text: 'text-[10px]' },
  md: { button: 'min-w-[60px] h-[60px] px-3 py-2', icon: 24, text: 'text-xs' },
  lg: { button: 'min-w-[72px] h-[72px] px-4 py-2.5', icon: 28, text: 'text-sm' },
};

// Layout-aware sizing (for horizontal/vertical modes)
const LAYOUT_CONFIG = {
  horizontal: {
    container: 'w-full h-full',  // Fill grid cell
    icon: 20,
    text: 'text-xs',
  },
  vertical: {
    container: 'w-full h-12 min-h-[48px]',  // 48px height, full width
    icon: 20,
    text: 'text-xs',
  },
};

/** Grid mode sizing (when layout='grid' without size prop) */
const GRID_ICON_SIZE = 18;
const GRID_TEXT_CLASS = 'text-[10px]';

// Default colors (match CSS tokens)
const DEFAULT_BG_COLOR = 'var(--color-bg-elevated)';
const DEFAULT_TEXT_COLOR = 'var(--color-text-primary)';
const DEFAULT_ICON_COLOR = 'var(--color-text-primary)';

export function ToolbarButton({
  action,
  toggleState,
  editMode,
  onEdit,
  onLongPress,
  layout = 'grid',
  size,
  dragProps,
  isDragTarget,
}: ToolbarButtonProps) {
  const { sendCommand } = useReaper();

  // Long-press detection (enters edit mode when not already editing)
  const longPressTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const longPressFired = useRef(false);

  const handlePointerDown = useCallback(() => {
    if (editMode || !onLongPress) return;
    longPressFired.current = false;
    longPressTimer.current = setTimeout(() => {
      longPressFired.current = true;
      onLongPress();
    }, LONG_PRESS_DELAY);
  }, [editMode, onLongPress]);

  const handlePointerUp = useCallback(() => {
    if (longPressTimer.current) {
      clearTimeout(longPressTimer.current);
      longPressTimer.current = null;
    }
  }, []);

  // Determine sizing based on layout mode
  // - horizontal/vertical: use LAYOUT_CONFIG
  // - grid: use SIZE_CONFIG (with size prop) or default grid sizing
  const layoutConfig = layout !== 'grid' ? LAYOUT_CONFIG[layout] : null;
  const sizeConfig = layout === 'grid' && size ? SIZE_CONFIG[size] : null;

  const iconSize = layoutConfig?.icon ?? sizeConfig?.icon ?? GRID_ICON_SIZE;
  const textClass = layoutConfig?.text ?? sizeConfig?.text ?? GRID_TEXT_CLASS;
  const buttonClass = layoutConfig?.container ?? sizeConfig?.button ?? 'w-full h-full px-1 py-0.5';

  const handleClick = useCallback(() => {
    // Suppress click if long-press just fired
    if (longPressFired.current) {
      longPressFired.current = false;
      return;
    }

    if (editMode) {
      onEdit();
      return;
    }

    // Execute action based on type
    switch (action.type) {
      case 'reaper_action':
        // Skip if actionId is missing (corrupted data)
        if (!action.actionId) break;
        // Use executeByName for SWS/scripts (actionId starts with "_")
        // Use execute for native REAPER actions (numeric actionId)
        if (action.actionId.startsWith('_')) {
          sendCommand(actionCmd.executeByName(action.actionId, action.sectionId));
        } else {
          sendCommand(actionCmd.execute(parseInt(action.actionId, 10), action.sectionId));
        }
        break;
      case 'midi_cc':
        sendCommand(midiCmd.cc(action.cc, action.value, action.channel));
        break;
      case 'midi_pc':
        sendCommand(midiCmd.pc(action.program, action.channel));
        break;
    }
  }, [action, editMode, onEdit, sendCommand]);

  // Compute colors - use user's colors, indicator dot shows toggle state
  const backgroundColor = action.backgroundColor || DEFAULT_BG_COLOR;
  const textColor = action.textColor || DEFAULT_TEXT_COLOR;
  const iconColor = action.iconColor || DEFAULT_ICON_COLOR;

  return (
    <button
      onClick={handleClick}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerLeave={handlePointerUp}
      onPointerCancel={handlePointerUp}
      {...dragProps}
      className={`
        relative flex flex-col items-center justify-center
        ${buttonClass}
        rounded-lg transition-all duration-100
        ${editMode ? 'ring-2 ring-edit-mode-ring cursor-grab active:cursor-grabbing' : ''}
        ${isDragTarget ? 'ring-2 ring-drag-target-ring scale-105' : ''}
        hover:brightness-110
        active:scale-95 active:brightness-75
      `}
      style={{ backgroundColor }}
      title={action.label}
    >
      {/* Icon */}
      {action.icon && (
        <DynamicIcon
          name={action.icon}
          size={iconSize}
          style={{ color: iconColor }}
          className={layout === 'grid' ? 'mt-0.5 mb-0.5 flex-shrink-0' : 'mt-0.5 mb-1 flex-shrink-0'}
        />
      )}

      {/* Label */}
      <span
        className={`${textClass} font-medium truncate max-w-full ${layout === 'grid' ? 'leading-tight' : ''}`}
        style={{ color: textColor }}
      >
        {action.label}
      </span>

      {/* Edit mode overlay */}
      {editMode && (
        <div className="absolute inset-0 flex items-center justify-center bg-black/40 rounded-lg">
          <Pencil size={16} className="text-white" />
        </div>
      )}

      {/* Toggle state indicator dot - show for REAPER actions with known toggle state */}
      {action.type === 'reaper_action' && toggleState !== undefined && toggleState !== -1 && (
        <div
          className={`absolute top-1 right-1 w-3 h-3 rounded-full border-2 border-white shadow-md ${
            toggleState === 1
              ? 'bg-success'
              : toggleState === 0
                ? 'bg-text-tertiary'
                : 'bg-warning' // undefined = loading
          }`}
        />
      )}
    </button>
  );
}
