/**
 * Toolbar - User-configurable action buttons
 * Horizontal scrollable button bar with edit mode
 * Collapse is now handled by parent CollapsibleSection wrapper
 */

import { useEffect, useCallback, useState, type ReactElement } from 'react';
import { Plus, Pencil, AlignLeft, AlignCenter, AlignRight } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useListReorder } from '../../hooks';
import { actionToggleState } from '../../core/WebSocketCommands';
import { ToolbarButton } from './ToolbarButton';
import { ToolbarEditor } from './ToolbarEditor';
import type { ToolbarAction, ToolbarAlign, ToggleStateEntry, NameToIdEntry } from '../../store/slices/toolbarSlice';
import { makeToggleKey } from '../../store/slices/toolbarSlice';

/**
 * Header controls for Toolbar section (Edit/Align/Add buttons)
 * Passed as headerControls to CollapsibleSection
 */
export function ToolbarHeaderControls(): ReactElement {
  const {
    toolbarEditMode,
    toolbarAlign,
    setToolbarEditMode,
    setToolbarAlign,
  } = useReaperStore();

  const handleToggleEditMode = useCallback(() => {
    setToolbarEditMode(!toolbarEditMode);
  }, [toolbarEditMode, setToolbarEditMode]);

  const handleAddClick = useCallback(() => {
    // Dispatch custom event that Toolbar component will listen for
    window.dispatchEvent(new CustomEvent('toolbar:add'));
  }, []);

  return (
    <div className="flex items-center gap-2">
      <button
        onClick={handleToggleEditMode}
        className={`px-2 py-1 text-xs rounded transition-colors flex items-center gap-1 ${
          toolbarEditMode
            ? 'bg-primary text-text-on-primary'
            : 'bg-bg-elevated hover:bg-bg-hover text-text-tertiary'
        }`}
      >
        <Pencil size={12} />
        {toolbarEditMode ? 'Done' : 'Edit'}
      </button>
      {toolbarEditMode && (
        <>
          {/* Alignment buttons */}
          <div className="flex items-center border border-border-default rounded overflow-hidden">
            {(['left', 'center', 'right'] as ToolbarAlign[]).map((align) => {
              const Icon = align === 'left' ? AlignLeft : align === 'center' ? AlignCenter : AlignRight;
              return (
                <button
                  key={align}
                  onClick={() => setToolbarAlign(align)}
                  className={`p-1.5 transition-colors ${
                    toolbarAlign === align
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
          <button
            onClick={handleAddClick}
            className="px-2 py-1 text-xs bg-success-action hover:bg-success text-text-on-success rounded transition-colors flex items-center gap-1"
          >
            <Plus size={12} />
            Add
          </button>
        </>
      )}
    </div>
  );
}

export function Toolbar(): ReactElement {
  const {
    toolbarActions,
    toolbarEditMode,
    toolbarAlign,
    toggleStates,
    loadToolbarFromStorage,
    addToolbarAction,
    updateToolbarAction,
    removeToolbarAction,
    reorderToolbarActions,
    updateToggleStates,
  } = useReaperStore();

  const { sendCommand, sendAsync, connectionStatus } = useReaper();
  const [editingAction, setEditingAction] = useState<ToolbarAction | null>(null);
  const [isAddingNew, setIsAddingNew] = useState(false);

  // Drag and drop via unified hook
  const { getDragItemProps, isDragTarget } = useListReorder({
    onReorder: reorderToolbarActions,
    enabled: toolbarEditMode,
  });

  // Load toolbar config from localStorage on mount
  useEffect(() => {
    loadToolbarFromStorage();
  }, [loadToolbarFromStorage]);

  // Listen for add button click from header controls
  useEffect(() => {
    const handleAdd = () => {
      setIsAddingNew(true);
      setEditingAction(null);
    };
    window.addEventListener('toolbar:add', handleAdd);
    return () => window.removeEventListener('toolbar:add', handleAdd);
  }, []);

  // Subscribe to toggle states when connected and toolbar has REAPER actions
  useEffect(() => {
    if (connectionStatus !== 'connected') return;

    // Extract section-aware action references
    const reaperActions = toolbarActions.filter(
      (a): a is ToolbarAction & { type: 'reaper_action' } => a.type === 'reaper_action'
    );

    // Section-aware numeric actions: {c: commandId, s: sectionId}
    const actions = reaperActions
      .filter((a) => a.actionId && !a.actionId.startsWith('_'))
      .map((a) => ({
        c: parseInt(a.actionId, 10),
        s: a.sectionId,
      }))
      .filter((a) => !isNaN(a.c));

    // Section-aware named actions: {n: name, s: sectionId}
    const namedActions = reaperActions
      .filter((a) => a.actionId && a.actionId.startsWith('_'))
      .map((a) => ({ n: a.actionId, s: a.sectionId }));

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
            states?: ToggleStateEntry[];
            nameToId?: NameToIdEntry[];
          };
        };
        if (resp.success && resp.payload?.states) {
          updateToggleStates(resp.payload.states, resp.payload.nameToId);
        }
      })
      .catch((err: Error) => {
        console.error('Failed to subscribe to toggle states:', err);
      });

    // Cleanup: unsubscribe on unmount or when actions change
    return () => {
      if (actions.length > 0) {
        sendCommand(actionToggleState.unsubscribe({ actions }));
      }
      // Note: Named commands are tracked by their resolved numeric ID internally,
      // but we don't need to explicitly unsubscribe - the server handles cleanup on disconnect
    };
  }, [connectionStatus, sendAsync, toolbarActions, sendCommand, updateToggleStates]);

  const handleEditClick = useCallback((action: ToolbarAction) => {
    setEditingAction(action);
    setIsAddingNew(false);
  }, []);

  const handleEditorClose = useCallback(() => {
    setEditingAction(null);
    setIsAddingNew(false);
  }, []);

  const handleEditorSave = useCallback(
    (action: ToolbarAction) => {
      if (isAddingNew) {
        addToolbarAction(action);
      } else {
        updateToolbarAction(action.id, action);
      }
      handleEditorClose();
    },
    [isAddingNew, addToolbarAction, updateToolbarAction, handleEditorClose]
  );

  const handleEditorDelete = useCallback(
    (id: string) => {
      removeToolbarAction(id);
      handleEditorClose();
    },
    [removeToolbarAction, handleEditorClose]
  );

  return (
    <>
      {/* Toolbar content */}
      <div className={`flex gap-2 overflow-x-auto p-1 pb-2 ${
        toolbarAlign === 'center' ? 'justify-center' :
        toolbarAlign === 'right' ? 'justify-end' : ''
      }`}>
        {toolbarActions.map((action, index) => (
          <ToolbarButton
            key={action.id}
            action={action}
            toggleState={
              action.type === 'reaper_action' && action.actionId
                ? toggleStates.get(makeToggleKey(action.sectionId, action.actionId))
                : undefined
            }
            editMode={toolbarEditMode}
            onEdit={() => handleEditClick(action)}
            dragProps={getDragItemProps(index)}
            isDragTarget={isDragTarget(index)}
          />
        ))}
        {toolbarActions.length === 0 && (
          <div className="text-text-muted text-sm py-4 px-2">
            {toolbarEditMode
              ? 'No toolbar buttons configured. Click "Add" to create one.'
              : 'No toolbar buttons. Click "Edit" to add some.'}
          </div>
        )}
      </div>

      {/* Editor Modal */}
      {(editingAction || isAddingNew) && (
        <ToolbarEditor
          action={editingAction}
          isNew={isAddingNew}
          onClose={handleEditorClose}
          onSave={handleEditorSave}
          onDelete={handleEditorDelete}
        />
      )}
    </>
  );
}
