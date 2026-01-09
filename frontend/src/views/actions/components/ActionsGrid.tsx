/**
 * ActionsGrid - Responsive flex wrapper for action buttons with alignment
 * Mobile-first: auto-wrapping buttons with configurable alignment
 */

import type { ReactElement } from 'react';
import { ToolbarButton } from '../../../components/Toolbar/ToolbarButton';
import type { ToolbarAction, ToggleState } from '../../../store/slices/toolbarSlice';
import type { SectionAlign, SizeOption } from '../../../store/slices/actionsViewSlice';
import type { UseListReorderReturn } from '../../../hooks';

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
  toggleStates: Map<string, ToggleState>;
  onEditAction: (action: ToolbarAction) => void;
  // Drag-drop via useListReorder hook
  getDragItemProps: UseListReorderReturn['getDragItemProps'];
  isDragTarget: UseListReorderReturn['isDragTarget'];
}

export function ActionsGrid({
  actions,
  align,
  buttonSize,
  buttonSpacing,
  editMode,
  toggleStates,
  onEditAction,
  getDragItemProps,
  isDragTarget,
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
            action.type === 'reaper_action' && action.actionId
              ? toggleStates.get(action.actionId)
              : undefined
          }
          editMode={editMode}
          onEdit={() => onEditAction(action)}
          size={buttonSize}
          dragProps={getDragItemProps(index)}
          isDragTarget={isDragTarget(index)}
        />
      ))}
    </div>
  );
}
