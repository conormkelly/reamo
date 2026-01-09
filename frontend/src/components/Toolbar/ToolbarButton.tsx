/**
 * ToolbarButton - Individual action button with toggle state support
 */

import { useCallback } from 'react';
import { Pencil } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { action as actionCmd, midi as midiCmd } from '../../core/WebSocketCommands';
import type { ToolbarAction, ToggleState } from '../../store/slices/toolbarSlice';
import { getIconComponent } from './DynamicIcon';

// Size variants for buttons
type ButtonSize = 'sm' | 'md' | 'lg';

interface ToolbarButtonProps {
  action: ToolbarAction;
  toggleState?: ToggleState;
  editMode: boolean;
  onEdit: () => void;
  size?: ButtonSize;
  // Drag and drop (edit mode only)
  index?: number;
  onDragStart?: (index: number) => void;
  onDragOver?: (index: number) => void;
  onDragEnd?: () => void;
  isDragTarget?: boolean;
}

// Size configurations
const SIZE_CONFIG = {
  sm: { button: 'min-w-[48px] h-[48px] px-2 py-1.5', icon: 18, text: 'text-[10px]' },
  md: { button: 'min-w-[60px] h-[60px] px-3 py-2', icon: 24, text: 'text-xs' },
  lg: { button: 'min-w-[72px] h-[72px] px-4 py-2.5', icon: 28, text: 'text-sm' },
};

// Default colors (match CSS tokens)
const DEFAULT_BG_COLOR = 'var(--color-bg-elevated)';
const DEFAULT_TEXT_COLOR = 'var(--color-text-primary)';
const DEFAULT_ICON_COLOR = 'var(--color-text-primary)';

export function ToolbarButton({
  action,
  toggleState,
  editMode,
  onEdit,
  size = 'md',
  index,
  onDragStart,
  onDragOver,
  onDragEnd,
  isDragTarget,
}: ToolbarButtonProps) {
  const sizeConfig = SIZE_CONFIG[size];
  const { sendCommand } = useReaper();

  const handleClick = useCallback(() => {
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

  // Get icon component
  const IconComponent = action.icon ? getIconComponent(action.icon) : null;

  const handleDragStart = useCallback(
    (e: React.DragEvent) => {
      if (!editMode || index === undefined || !onDragStart) return;
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', String(index));
      onDragStart(index);
    },
    [editMode, index, onDragStart]
  );

  const handleDragOver = useCallback(
    (e: React.DragEvent) => {
      if (!editMode || index === undefined || !onDragOver) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      onDragOver(index);
    },
    [editMode, index, onDragOver]
  );

  const handleDragEnd = useCallback(() => {
    onDragEnd?.();
  }, [onDragEnd]);

  return (
    <button
      onClick={handleClick}
      draggable={editMode}
      onDragStart={handleDragStart}
      onDragOver={handleDragOver}
      onDragEnd={handleDragEnd}
      className={`
        relative flex flex-col items-center justify-center
        ${sizeConfig.button}
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
      {IconComponent && (
        <IconComponent
          size={sizeConfig.icon}
          style={{ color: iconColor }}
          className="mb-1"
        />
      )}

      {/* Label */}
      <span
        className={`${sizeConfig.text} font-medium truncate max-w-full`}
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

      {/* Toggle state indicator dot - always show for REAPER actions (except non-toggles) */}
      {action.type === 'reaper_action' && toggleState !== -1 && (
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
