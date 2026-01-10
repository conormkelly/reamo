/**
 * ActionsView - User-configurable quick action buttons organized in sections
 * Mobile-first grid layout with named sections (like a phone home screen)
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import {
  Pencil,
  Plus,
  LayoutGrid,
  AlignVerticalJustifyStart,
  AlignVerticalJustifyCenter,
  AlignVerticalJustifyEnd,
} from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../../components/ReaperProvider';
import { ViewHeader } from '../../components';
import { useUIPreferences } from '../../hooks';
import { actionToggleState } from '../../core/WebSocketCommands';
import { ActionsSection, SectionEditor } from './components';
import { ToolbarEditor } from '../../components/Toolbar/ToolbarEditor';
import type { ToolbarAction } from '../../store/slices/toolbarSlice';
import type {
  ActionsSection as ActionsSectionType,
  VerticalAlign,
  SizeOption,
} from '../../store/slices/actionsViewSlice';

// Fixed heights for bottom bar calculations (must match App.tsx)
const TAB_BAR_HEIGHT = 48;
const PERSISTENT_TRANSPORT_HEIGHT = 56;

export function ActionsView(): ReactElement {
  const { sendCommand, sendAsync, connectionStatus } = useReaper();
  const { showTabBar, showPersistentTransport } = useUIPreferences();

  // Calculate bottom offset for footer bars
  const bottomOffset =
    (showTabBar ? TAB_BAR_HEIGHT : 0) +
    (showPersistentTransport ? PERSISTENT_TRANSPORT_HEIGHT : 0);

  // Store selectors
  const sections = useReaperStore((s) => s.actionsSections);
  const editMode = useReaperStore((s) => s.actionsEditMode);
  const toggleStates = useReaperStore((s) => s.toggleStates); // Shared with Toolbar
  const updateToggleStates = useReaperStore((s) => s.updateToggleStates);
  const verticalAlign = useReaperStore((s) => s.actionsVerticalAlign);
  const loadFromStorage = useReaperStore((s) => s.loadActionsViewFromStorage);
  const setEditMode = useReaperStore((s) => s.setActionsEditMode);
  const setVerticalAlign = useReaperStore((s) => s.setActionsVerticalAlign);
  const addSection = useReaperStore((s) => s.addSection);
  const updateSection = useReaperStore((s) => s.updateSection);
  const removeSection = useReaperStore((s) => s.removeSection);
  const toggleSectionCollapse = useReaperStore((s) => s.toggleSectionCollapse);
  const setSectionAlign = useReaperStore((s) => s.setSectionAlign);
  const reorderSections = useReaperStore((s) => s.reorderSections);
  const addActionToSection = useReaperStore((s) => s.addActionToSection);
  const updateActionInSection = useReaperStore((s) => s.updateActionInSection);
  const removeActionFromSection = useReaperStore((s) => s.removeActionFromSection);
  const reorderActionsInSection = useReaperStore((s) => s.reorderActionsInSection);
  const getActionRefs = useReaperStore((s) => s.getActionsReaperActionRefs);

  // Local modal state
  const [editingSection, setEditingSection] = useState<ActionsSectionType | null>(null);
  const [isAddingSection, setIsAddingSection] = useState(false);
  const [editingAction, setEditingAction] = useState<{
    sectionId: string;
    action: ToolbarAction;
  } | null>(null);
  const [addingToSectionId, setAddingToSectionId] = useState<string | null>(null);

  // Section drag state
  const [sectionDragFromIdx, setSectionDragFromIdx] = useState<number | null>(null);
  const [sectionDragOverIdx, setSectionDragOverIdx] = useState<number | null>(null);

  // Load from storage on mount
  useEffect(() => {
    loadFromStorage();
  }, [loadFromStorage]);

  // Subscribe to toggle states when connected (mirrors Toolbar pattern)
  useEffect(() => {
    if (connectionStatus !== 'connected') return;

    const { actions, namedActions } = getActionRefs();
    if (actions.length === 0 && namedActions.length === 0) return;

    // Subscribe to toggle states with section-aware format
    const cmd = actionToggleState.subscribe({
      actions: actions.length > 0 ? actions : undefined,
      namedActions: namedActions.length > 0 ? namedActions : undefined,
    });
    sendAsync(cmd.command, cmd.params)
      .then((response: unknown) => {
        const resp = response as {
          success?: boolean;
          payload?: {
            states?: Array<{ s: number; c: number; v: number }>;
            nameToId?: Array<{ n: string; s: number; c: number }>;
          };
        };
        if (resp.success && resp.payload?.states) {
          updateToggleStates(resp.payload.states, resp.payload.nameToId);
        }
      })
      .catch((err: Error) => {
        console.error('Failed to subscribe to toggle states:', err);
      });

    // Cleanup: unsubscribe when view unmounts or sections change
    return () => {
      if (actions.length > 0 || namedActions.length > 0) {
        sendCommand(actionToggleState.unsubscribe({
          actions: actions.length > 0 ? actions : undefined,
          namedActions: namedActions.length > 0 ? namedActions : undefined,
        }));
      }
    };
  }, [connectionStatus, sendAsync, sections, sendCommand, getActionRefs, updateToggleStates]);

  // Section drag handlers
  const handleSectionDragStart = useCallback((index: number) => {
    setSectionDragFromIdx(index);
  }, []);

  const handleSectionDragOver = useCallback((index: number) => {
    setSectionDragOverIdx(index);
  }, []);

  const handleSectionDragEnd = useCallback(() => {
    if (
      sectionDragFromIdx !== null &&
      sectionDragOverIdx !== null &&
      sectionDragFromIdx !== sectionDragOverIdx
    ) {
      reorderSections(sectionDragFromIdx, sectionDragOverIdx);
    }
    setSectionDragFromIdx(null);
    setSectionDragOverIdx(null);
  }, [sectionDragFromIdx, sectionDragOverIdx, reorderSections]);

  // Section CRUD handlers
  const handleAddSection = useCallback(
    (data: { name: string; icon?: string; color?: string; buttonSize?: SizeOption; buttonSpacing?: SizeOption }) => {
      addSection(data);
    },
    [addSection]
  );

  const handleUpdateSection = useCallback(
    (data: { name: string; icon?: string; color?: string; buttonSize?: SizeOption; buttonSpacing?: SizeOption }) => {
      if (editingSection) {
        updateSection(editingSection.id, data);
      }
    },
    [editingSection, updateSection]
  );

  const handleDeleteSection = useCallback(() => {
    if (editingSection) {
      removeSection(editingSection.id);
    }
  }, [editingSection, removeSection]);

  // Action CRUD handlers
  const handleSaveAction = useCallback(
    (action: ToolbarAction) => {
      if (editingAction) {
        // Editing existing action
        updateActionInSection(editingAction.sectionId, action.id, action);
      } else if (addingToSectionId) {
        // Adding new action
        addActionToSection(addingToSectionId, action);
      }
      // Close modal after save
      setAddingToSectionId(null);
      setEditingAction(null);
    },
    [editingAction, addingToSectionId, updateActionInSection, addActionToSection]
  );

  const handleDeleteAction = useCallback(
    (actionId: string) => {
      if (editingAction) {
        removeActionFromSection(editingAction.sectionId, actionId);
      }
      // Close modal after delete
      setAddingToSectionId(null);
      setEditingAction(null);
    },
    [editingAction, removeActionFromSection]
  );

  // Vertical alignment classes
  const verticalAlignClass =
    verticalAlign === 'center'
      ? 'justify-center'
      : verticalAlign === 'bottom'
        ? 'justify-end'
        : 'justify-start';

  return (
    <div className="h-full bg-bg-app text-text-primary flex flex-col p-3">
      {/* Header with ViewHeader + edit controls */}
      <ViewHeader currentView="actions">
        {/* Vertical alignment buttons (edit mode only) */}
        {editMode && (
          <div className="flex items-center border border-border-default rounded overflow-hidden">
            {(['top', 'center', 'bottom'] as VerticalAlign[]).map((align) => {
              const Icon =
                align === 'top'
                  ? AlignVerticalJustifyStart
                  : align === 'center'
                    ? AlignVerticalJustifyCenter
                    : AlignVerticalJustifyEnd;
              return (
                <button
                  key={align}
                  onClick={() => setVerticalAlign(align)}
                  className={`p-1.5 transition-colors ${
                    verticalAlign === align
                      ? 'bg-primary text-text-on-primary'
                      : 'bg-bg-elevated text-text-secondary hover:bg-bg-hover'
                  }`}
                  title={`Align sections ${align}`}
                >
                  <Icon size={16} />
                </button>
              );
            })}
          </div>
        )}

        {/* Add section button (edit mode only) */}
        {editMode && (
          <button
            onClick={() => setIsAddingSection(true)}
            className="flex items-center gap-1.5 px-3 py-1.5 bg-success-action text-text-on-success rounded-lg hover:bg-success transition-colors"
          >
            <Plus size={16} />
            <span className="text-sm">Section</span>
          </button>
        )}

        {/* Edit mode toggle */}
        <button
          onClick={() => setEditMode(!editMode)}
          className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg transition-colors ${
            editMode
              ? 'bg-primary text-text-on-primary'
              : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
          }`}
        >
          <Pencil size={16} />
          <span className="text-sm">{editMode ? 'Done' : 'Edit'}</span>
        </button>
      </ViewHeader>

      {/* Content */}
      {sections.length === 0 ? (
        // Empty state - position at bottom with padding for footer bars
        <div
          className="flex-1 overflow-auto flex flex-col justify-end"
          style={{ paddingBottom: `${bottomOffset + 24}px` }}
        >
          <div className="flex flex-col items-center text-center py-8">
            <LayoutGrid size={48} className="text-text-disabled mb-4" />
            <h2 className="text-xl font-medium text-text-tertiary mb-2">No Sections Yet</h2>
            <p className="text-text-muted mb-6 max-w-xs">
              Add buttons that trigger REAPER actions or send MIDI. Organize them into named sections.
            </p>
            <button
              onClick={() => {
                setEditMode(true);
                setIsAddingSection(true);
              }}
              className="flex items-center gap-2 px-4 py-2 bg-primary text-text-on-primary rounded-lg hover:bg-primary-hover transition-colors"
            >
              <Plus size={18} />
              <span>Create Section</span>
            </button>
          </div>
        </div>
      ) : (
        // Sections list - uses verticalAlign preference
        <div className={`flex-1 overflow-auto p-4 pt-0 flex flex-col ${verticalAlignClass}`}>
          <div className="space-y-4">
            {sections.map((section, index) => (
              <ActionsSection
                key={section.id}
                section={section}
                editMode={editMode}
                toggleStates={toggleStates}
                onToggleCollapse={() => toggleSectionCollapse(section.id)}
                onEditSection={() => setEditingSection(section)}
                onSetAlign={(align) => setSectionAlign(section.id, align)}
                onAddAction={() => setAddingToSectionId(section.id)}
                onEditAction={(action) =>
                  setEditingAction({ sectionId: section.id, action })
                }
                onReorderActions={(from, to) =>
                  reorderActionsInSection(section.id, from, to)
                }
                index={index}
                onDragSectionStart={handleSectionDragStart}
                onDragSectionOver={handleSectionDragOver}
                onDragSectionEnd={handleSectionDragEnd}
                isSectionDragTarget={
                  sectionDragOverIdx === index &&
                  sectionDragFromIdx !== null &&
                  sectionDragFromIdx !== index
                }
              />
            ))}
          </div>
        </div>
      )}

      {/* Section editor modal */}
      {(isAddingSection || editingSection) && (
        <SectionEditor
          section={editingSection}
          onSave={editingSection ? handleUpdateSection : handleAddSection}
          onDelete={editingSection ? handleDeleteSection : undefined}
          onClose={() => {
            setIsAddingSection(false);
            setEditingSection(null);
          }}
        />
      )}

      {/* Action editor modal (reuse ToolbarEditor) */}
      {(addingToSectionId || editingAction) && (
        <ToolbarEditor
          action={editingAction?.action ?? null}
          isNew={!editingAction}
          editorTitle="Action Button"
          onSave={handleSaveAction}
          onDelete={handleDeleteAction}
          onClose={() => {
            setAddingToSectionId(null);
            setEditingAction(null);
          }}
        />
      )}
    </div>
  );
}
