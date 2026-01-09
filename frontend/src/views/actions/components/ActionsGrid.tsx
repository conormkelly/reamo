/**
 * ActionsGrid - Responsive flex wrapper for action buttons with alignment
 * Mobile-first: auto-wrapping buttons with configurable alignment
 */

import type { ReactElement } from 'react';
import { ToolbarButton } from '../../../components/Toolbar/ToolbarButton';
import type { ToolbarAction, ToggleState } from '../../../store/slices/toolbarSlice';
import type { SectionAlign, SizeOption } from '../../../store/slices/actionsViewSlice';

// Gap classes for spacing options
const SPACING_CLASSES = {
  sm: 'gap-1',
  md: 'gap-2',
  lg: 'gap-3',
};

interface ActionsGridProps {
  actions: ToolbarAction[];
  align: SectionAlign;
  buttonSize: SizeOption;
  buttonSpacing: SizeOption;
  editMode: boolean;
  toggleStates: Map<number, ToggleState>;
  onEditAction: (action: ToolbarAction) => void;
  // Drag-drop for action reordering within grid
  dragFromIdx: number | null;
  dragOverIdx: number | null;
  onDragStart: (index: number) => void;
  onDragOver: (index: number) => void;
  onDragEnd: () => void;
}

export function ActionsGrid({
  actions,
  align,
  buttonSize,
  buttonSpacing,
  editMode,
  toggleStates,
  onEditAction,
  dragFromIdx,
  dragOverIdx,
  onDragStart,
  onDragOver,
  onDragEnd,
}: ActionsGridProps): ReactElement {
  // Alignment classes for flex container
  const alignClass =
    align === 'center'
      ? 'justify-center'
      : align === 'right'
        ? 'justify-end'
        : 'justify-start';

  const spacingClass = SPACING_CLASSES[buttonSpacing];

  return (
    <div className={`flex flex-wrap ${spacingClass} ${alignClass}`}>
      {actions.map((action, index) => (
        <ToolbarButton
          key={action.id}
          action={action}
          toggleState={
            action.type === 'reaper_action' && action.actionId && !action.actionId.startsWith('_')
              ? toggleStates.get(parseInt(action.actionId, 10))
              : undefined
          }
          editMode={editMode}
          onEdit={() => onEditAction(action)}
          size={buttonSize}
          index={index}
          onDragStart={onDragStart}
          onDragOver={onDragOver}
          onDragEnd={onDragEnd}
          isDragTarget={dragOverIdx === index && dragFromIdx !== null && dragFromIdx !== index}
        />
      ))}
    </div>
  );
}
