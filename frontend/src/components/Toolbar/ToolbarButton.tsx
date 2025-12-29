/**
 * ToolbarButton - Individual action button with toggle state support
 */

import { useCallback } from 'react';
import { Pencil, icons, type LucideIcon } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { action as actionCmd } from '../../core/WebSocketCommands';
import type { ToolbarAction, ToggleState } from '../../store/slices/toolbarSlice';

interface ToolbarButtonProps {
  action: ToolbarAction;
  toggleState?: ToggleState;
  editMode: boolean;
  onEdit: () => void;
}

// Default colors
const DEFAULT_BG_COLOR = '#374151'; // gray-700
const DEFAULT_TEXT_COLOR = '#FFFFFF';
const DEFAULT_ICON_COLOR = '#000000';

// Get icon component by name
function getIconComponent(name: string): LucideIcon | null {
  // Convert kebab-case to PascalCase for icon lookup
  const pascalName = name
    .split('-')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join('');

  return (icons as Record<string, LucideIcon>)[pascalName] || null;
}

export function ToolbarButton({
  action,
  toggleState,
  editMode,
  onEdit,
}: ToolbarButtonProps) {
  const { sendCommand } = useReaper();

  const handleClick = useCallback(() => {
    if (editMode) {
      onEdit();
      return;
    }

    // Execute action based on type
    switch (action.type) {
      case 'reaper_action':
        sendCommand(actionCmd.execute(action.commandId));
        break;
      case 'reaper_action_name':
        sendCommand(actionCmd.executeByName(action.name));
        break;
      case 'midi_cc':
        // TODO: Implement when backend MIDI commands are ready
        console.log('MIDI CC not yet implemented:', action);
        break;
      case 'midi_pc':
        // TODO: Implement when backend MIDI commands are ready
        console.log('MIDI PC not yet implemented:', action);
        break;
    }
  }, [action, editMode, onEdit, sendCommand]);

  // Debug: log toggle state
  console.log(`[ToolbarButton] ${action.label} toggleState:`, toggleState);

  // Compute colors - use user's colors, indicator dot shows toggle state
  const backgroundColor = action.backgroundColor || DEFAULT_BG_COLOR;
  const textColor = action.textColor || DEFAULT_TEXT_COLOR;
  const iconColor = action.iconColor || DEFAULT_ICON_COLOR;

  // Get icon component
  const IconComponent = action.icon ? getIconComponent(action.icon) : null;

  return (
    <button
      onClick={handleClick}
      className={`
        relative flex flex-col items-center justify-center
        min-w-[60px] h-[60px] px-3 py-2
        rounded-lg transition-all
        ${editMode ? 'ring-2 ring-blue-400 ring-opacity-50' : ''}
        hover:brightness-110 active:brightness-90
      `}
      style={{ backgroundColor }}
      title={action.label}
    >
      {/* Icon */}
      {IconComponent && (
        <IconComponent
          size={24}
          style={{ color: iconColor }}
          className="mb-1"
        />
      )}

      {/* Label */}
      <span
        className="text-xs font-medium truncate max-w-full"
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
              ? 'bg-green-500'
              : toggleState === 0
                ? 'bg-gray-300'
                : 'bg-yellow-500' // undefined = loading
          }`}
        />
      )}
    </button>
  );
}
