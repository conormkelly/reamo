/**
 * ActionsSection - Collapsible section containing a grid of action buttons
 */

import { useState, useCallback, type ReactElement } from 'react';
import {
  ChevronDown,
  GripVertical,
  Pencil,
  Plus,
  AlignLeft,
  AlignCenter,
  AlignRight,
  icons,
  type LucideIcon,
} from 'lucide-react';

// Get icon component by name (kebab-case to PascalCase)
function getIconComponent(name: string): LucideIcon | null {
  const pascalName = name
    .split('-')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join('');
  return (icons as Record<string, LucideIcon>)[pascalName] || null;
}
import { ActionsGrid } from './ActionsGrid';
import type {
  ActionsSection as ActionsSectionType,
  SectionAlign,
} from '../../../store/slices/actionsViewSlice';
import type { ToolbarAction, ToggleState } from '../../../store/slices/toolbarSlice';

interface ActionsSectionProps {
  section: ActionsSectionType;
  editMode: boolean;
  toggleStates: Map<number, ToggleState>;
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
  // Local drag state for actions within this section
  const [dragFromIdx, setDragFromIdx] = useState<number | null>(null);
  const [dragOverIdx, setDragOverIdx] = useState<number | null>(null);

  const handleActionDragStart = useCallback((idx: number) => {
    setDragFromIdx(idx);
  }, []);

  const handleActionDragOver = useCallback((idx: number) => {
    setDragOverIdx(idx);
  }, []);

  const handleActionDragEnd = useCallback(() => {
    if (dragFromIdx !== null && dragOverIdx !== null && dragFromIdx !== dragOverIdx) {
      onReorderActions(dragFromIdx, dragOverIdx);
    }
    setDragFromIdx(null);
    setDragOverIdx(null);
  }, [dragFromIdx, dragOverIdx, onReorderActions]);

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
      className={`bg-gray-900 rounded-lg overflow-hidden transition-all ${
        editMode ? 'ring-1 ring-blue-500/30' : ''
      } ${isSectionDragTarget ? 'ring-2 ring-yellow-400 scale-[1.02]' : ''}`}
      style={{
        borderLeft: section.color ? `4px solid ${section.color}` : undefined,
      }}
      onDragOver={handleSectionDragOver}
    >
      {/* Section header */}
      <div
        className={`flex items-center gap-2 p-3 border-b border-gray-800 ${
          editMode ? 'cursor-grab active:cursor-grabbing' : ''
        }`}
        draggable={editMode}
        onDragStart={handleSectionDragStart}
        onDragEnd={handleSectionDragEnd}
      >
        {/* Drag handle (edit mode only) */}
        {editMode && (
          <GripVertical size={18} className="text-gray-500 flex-shrink-0" />
        )}

        {/* Collapse toggle + name */}
        <button
          onClick={onToggleCollapse}
          className="flex-1 flex items-center gap-2 text-left min-w-0"
        >
          <ChevronDown
            size={18}
            className={`text-gray-400 flex-shrink-0 transition-transform ${
              section.collapsed ? '-rotate-90' : ''
            }`}
          />
          {IconComponent && (
            <IconComponent
              size={18}
              className="flex-shrink-0"
              style={{ color: section.color || '#9ca3af' }}
            />
          )}
          <span className="font-medium text-white truncate">{section.name}</span>
          <span className="text-sm text-gray-500">({section.actions.length})</span>
        </button>

        {/* Alignment buttons (edit mode only) */}
        {editMode && (
          <div className="flex items-center border border-gray-600 rounded overflow-hidden">
            {(['left', 'center', 'right'] as SectionAlign[]).map((align) => {
              const Icon =
                align === 'left' ? AlignLeft : align === 'center' ? AlignCenter : AlignRight;
              return (
                <button
                  key={align}
                  onClick={() => onSetAlign(align)}
                  className={`p-1 transition-colors ${
                    section.align === align
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-700 text-gray-400 hover:bg-gray-600'
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
            className="p-1.5 text-gray-400 hover:text-white hover:bg-gray-700 rounded-lg transition-colors"
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
              dragFromIdx={dragFromIdx}
              dragOverIdx={dragOverIdx}
              onDragStart={handleActionDragStart}
              onDragOver={handleActionDragOver}
              onDragEnd={handleActionDragEnd}
            />
          ) : (
            <div className="text-center text-gray-500 py-4">
              {editMode ? 'No actions yet. Tap + to add.' : 'No actions configured'}
            </div>
          )}

          {/* Add action button (edit mode only) */}
          {editMode && (
            <button
              onClick={onAddAction}
              className="w-full mt-3 py-2 border-2 border-dashed border-gray-700 rounded-lg text-gray-400 hover:border-gray-500 hover:text-gray-300 transition-colors flex items-center justify-center gap-2"
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
