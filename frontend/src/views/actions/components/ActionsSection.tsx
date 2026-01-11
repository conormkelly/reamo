/**
 * ActionsSection - Collapsible section containing a grid of action buttons
 */

import { useCallback, type ReactElement } from 'react';
import {
  ChevronDown,
  GripVertical,
  Pencil,
  Plus,
  AlignLeft,
  AlignCenter,
  AlignRight,
} from 'lucide-react';
import { getIconComponent } from '../../../components/Toolbar/DynamicIcon';
import { ActionsGrid } from './ActionsGrid';
import { useListReorder } from '../../../hooks';
import type {
  ActionsSection as ActionsSectionType,
  SectionAlign,
} from '../../../store/slices/actionsViewSlice';
import type { ToolbarAction, ToggleState } from '../../../store/slices/toolbarSlice';

interface ActionsSectionProps {
  section: ActionsSectionType;
  editMode: boolean;
  toggleStates: Map<string, ToggleState>;
  onToggleCollapse: () => void;
  onEditSection: () => void;
  onSetAlign: (align: SectionAlign) => void;
  onAddAction: () => void;
  onEditAction: (action: ToolbarAction) => void;
  onReorderActions: (fromIndex: number, toIndex: number) => void;
  // Section drag-drop (edit mode only)
  index: number;
  onDragSectionStart?: (index: number) => void;
  onDragSectionOver?: (index: number) => void;
  onDragSectionEnd?: () => void;
  isSectionDragTarget?: boolean;
}

export function ActionsSection({
  section,
  editMode,
  toggleStates,
  onToggleCollapse,
  onEditSection,
  onSetAlign,
  onAddAction,
  onEditAction,
  onReorderActions,
  index,
  onDragSectionStart,
  onDragSectionOver,
  onDragSectionEnd,
  isSectionDragTarget,
}: ActionsSectionProps): ReactElement {
  // Action drag via unified hook
  const { getDragItemProps, isDragTarget } = useListReorder({
    onReorder: onReorderActions,
    enabled: editMode,
  });

  // Section drag handlers
  const handleSectionDragStart = useCallback(
    (e: React.DragEvent) => {
      if (!editMode || !onDragSectionStart) return;
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', String(index));
      onDragSectionStart(index);
    },
    [editMode, index, onDragSectionStart]
  );

  const handleSectionDragOver = useCallback(
    (e: React.DragEvent) => {
      if (!editMode || !onDragSectionOver) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      onDragSectionOver(index);
    },
    [editMode, index, onDragSectionOver]
  );

  const handleSectionDragEnd = useCallback(() => {
    onDragSectionEnd?.();
  }, [onDragSectionEnd]);

  // Get icon component if specified
  const IconComponent = section.icon ? getIconComponent(section.icon) : null;

  return (
    <div
      className={`bg-bg-deep rounded-lg overflow-hidden transition-all ${
        editMode ? 'ring-1 ring-edit-mode-ring' : ''
      } ${isSectionDragTarget ? 'ring-2 ring-drag-target-ring scale-[1.02]' : ''}`}
      style={{
        borderLeft: section.color ? `4px solid ${section.color}` : undefined,
      }}
      onDragOver={handleSectionDragOver}
    >
      {/* Section header */}
      <div
        className={`flex items-center gap-2 p-3 border-b border-border-muted ${
          editMode ? 'cursor-grab active:cursor-grabbing' : ''
        }`}
        draggable={editMode}
        onDragStart={handleSectionDragStart}
        onDragEnd={handleSectionDragEnd}
      >
        {/* Drag handle (edit mode only) */}
        {editMode && (
          <GripVertical size={18} className="text-text-muted flex-shrink-0" />
        )}

        {/* Collapse toggle + name */}
        <button
          onClick={onToggleCollapse}
          className="flex-1 flex items-center gap-2 text-left min-w-0"
        >
          <ChevronDown
            size={18}
            className={`text-text-secondary flex-shrink-0 transition-transform ${
              section.collapsed ? '-rotate-90' : ''
            }`}
          />
          {IconComponent && (
            <IconComponent
              size={18}
              className="flex-shrink-0"
              style={{ color: section.color || 'var(--color-text-secondary)' }}
            />
          )}
          <span className="font-medium text-text-primary truncate">{section.name}</span>
          <span className="text-sm text-text-muted">({section.actions.length})</span>
        </button>

        {/* Alignment buttons (edit mode only) */}
        {editMode && (
          <div className="flex items-center border border-border-default rounded overflow-hidden">
            {(['left', 'center', 'right'] as SectionAlign[]).map((align) => {
              const Icon =
                align === 'left' ? AlignLeft : align === 'center' ? AlignCenter : AlignRight;
              return (
                <button
                  key={align}
                  onClick={() => onSetAlign(align)}
                  className={`p-1 transition-colors ${
                    section.align === align
                      ? 'bg-primary text-text-on-primary'
                      : 'bg-bg-elevated text-text-secondary hover:bg-bg-hover'
                  }`}
                  title={`Align ${align}`}
                >
                  <Icon size={14} />
                </button>
              );
            })}
          </div>
        )}

        {/* Edit button (edit mode only) */}
        {editMode && (
          <button
            onClick={onEditSection}
            className="p-1.5 text-text-secondary hover:text-text-primary hover:bg-bg-elevated rounded-lg transition-colors"
          >
            <Pencil size={16} />
          </button>
        )}
      </div>

      {/* Actions grid (collapsible) */}
      {!section.collapsed && (
        <div className="p-3">
          {section.actions.length > 0 ? (
            <ActionsGrid
              actions={section.actions}
              align={section.align}
              buttonSize={section.buttonSize}
              buttonSpacing={section.buttonSpacing}
              editMode={editMode}
              toggleStates={toggleStates}
              onEditAction={onEditAction}
              getDragItemProps={getDragItemProps}
              isDragTarget={isDragTarget}
            />
          ) : (
            <div className="text-center text-text-muted py-4">
              {editMode ? 'No actions yet. Tap + to add.' : 'No actions configured'}
            </div>
          )}

          {/* Add action button (edit mode only) */}
          {editMode && (
            <button
              onClick={onAddAction}
              className="w-full mt-3 py-2 border-2 border-dashed border-border-subtle rounded-lg text-text-secondary hover:border-bg-hover hover:text-text-tertiary transition-colors flex items-center justify-center gap-2"
            >
              <Plus size={16} />
              <span>Add Action</span>
            </button>
          )}
        </div>
      )}
    </div>
  );
}
