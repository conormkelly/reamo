/**
 * Toolbar - User-configurable action buttons
 * Collapsible section with horizontal scrollable button bar
 */

import { useEffect, useCallback, useState } from 'react';
import { ChevronDown, ChevronRight, Plus, Pencil } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { actionToggleState } from '../../core/WebSocketCommands';
import { ToolbarButton } from './ToolbarButton';
import { ToolbarEditor } from './ToolbarEditor';
import type { ToolbarAction } from '../../store/slices/toolbarSlice';

export function Toolbar() {
  const {
    toolbarActions,
    toolbarCollapsed,
    toolbarEditMode,
    toggleStates,
    setToolbarCollapsed,
    setToolbarEditMode,
    loadToolbarFromStorage,
    addToolbarAction,
    updateToolbarAction,
    removeToolbarAction,
    updateToggleStates,
  } = useReaperStore();

  const { sendCommand, connection, connectionState } = useReaper();
  const [editingAction, setEditingAction] = useState<ToolbarAction | null>(null);
  const [isAddingNew, setIsAddingNew] = useState(false);

  // Load toolbar config from localStorage on mount
  useEffect(() => {
    loadToolbarFromStorage();
  }, [loadToolbarFromStorage]);

  // Subscribe to toggle states when connected and toolbar has REAPER actions
  useEffect(() => {
    if (connectionState !== 'connected' || !connection) return;

    // Extract commandIds from REAPER action buttons
    const commandIds = toolbarActions
      .filter((a): a is ToolbarAction & { type: 'reaper_action' } => a.type === 'reaper_action')
      .map((a) => a.commandId);

    if (commandIds.length === 0) return;

    // Subscribe to toggle states and get initial snapshot
    const cmd = actionToggleState.subscribe(commandIds);
    console.log('[Toolbar] Subscribing to toggle states for:', commandIds);
    connection
      .sendAsync(cmd.command, cmd.params)
      .then((response: unknown) => {
        console.log('[Toolbar] Toggle state subscription response:', response);
        const resp = response as { success?: boolean; payload?: { states?: Record<string, number> } };
        if (resp.success && resp.payload?.states) {
          console.log('[Toolbar] Updating toggle states:', resp.payload.states);
          updateToggleStates(resp.payload.states);
        } else {
          console.warn('[Toolbar] No states in response:', resp);
        }
      })
      .catch((err) => {
        console.error('Failed to subscribe to toggle states:', err);
      });

    // Cleanup: unsubscribe on unmount or when actions change
    return () => {
      if (commandIds.length > 0) {
        sendCommand(actionToggleState.unsubscribe(commandIds));
      }
    };
  }, [connectionState, connection, toolbarActions, sendCommand, updateToggleStates]);

  const handleToggleCollapse = useCallback(() => {
    setToolbarCollapsed(!toolbarCollapsed);
  }, [toolbarCollapsed, setToolbarCollapsed]);

  const handleToggleEditMode = useCallback(() => {
    setToolbarEditMode(!toolbarEditMode);
  }, [toolbarEditMode, setToolbarEditMode]);

  const handleAddClick = useCallback(() => {
    setIsAddingNew(true);
    setEditingAction(null);
  }, []);

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
    <section className="mb-4">
      <div className="flex items-center justify-between mb-2">
        <button
          onClick={handleToggleCollapse}
          className="flex items-center gap-1 text-sm font-medium text-gray-400 hover:text-gray-300 transition-colors"
        >
          {toolbarCollapsed ? <ChevronRight size={16} /> : <ChevronDown size={16} />}
          <h3>Toolbar</h3>
        </button>
        {!toolbarCollapsed && (
          <div className="flex items-center gap-2">
            <button
              onClick={handleToggleEditMode}
              className={`px-2 py-1 text-xs rounded transition-colors flex items-center gap-1 ${
                toolbarEditMode
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-700 hover:bg-gray-600 text-gray-300'
              }`}
            >
              <Pencil size={12} />
              {toolbarEditMode ? 'Done' : 'Edit'}
            </button>
            {toolbarEditMode && (
              <button
                onClick={handleAddClick}
                className="px-2 py-1 text-xs bg-green-600 hover:bg-green-500 text-white rounded transition-colors flex items-center gap-1"
              >
                <Plus size={12} />
                Add
              </button>
            )}
          </div>
        )}
      </div>

      {!toolbarCollapsed && (
        <div className="flex gap-2 overflow-x-auto pb-2">
          {toolbarActions.map((action) => {
            const ts = action.type === 'reaper_action'
              ? toggleStates.get(action.commandId)
              : undefined;
            console.log(`[Toolbar] Rendering ${action.label}, commandId=${action.type === 'reaper_action' ? action.commandId : 'N/A'}, toggleState=${ts}, mapSize=${toggleStates.size}`);
            return (
              <ToolbarButton
                key={action.id}
                action={action}
                toggleState={ts}
                editMode={toolbarEditMode}
                onEdit={() => handleEditClick(action)}
              />
            );
          })}
          {toolbarActions.length === 0 && (
            <div className="text-gray-500 text-sm py-4 px-2">
              {toolbarEditMode
                ? 'No toolbar buttons configured. Click "Add" to create one.'
                : 'No toolbar buttons. Click "Edit" to add some.'}
            </div>
          )}
        </div>
      )}

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
    </section>
  );
}
