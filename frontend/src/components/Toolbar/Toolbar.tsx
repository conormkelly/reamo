/**
 * Toolbar - User-configurable action buttons
 * Horizontal scrollable button bar with edit mode
 * Collapse is now handled by parent CollapsibleSection wrapper
 */

import { useEffect, useCallback, useState, type ReactElement } from 'react';
import { Plus, Pencil, AlignLeft, AlignCenter, AlignRight } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { actionToggleState } from '../../core/WebSocketCommands';
import { ToolbarButton } from './ToolbarButton';
import { ToolbarEditor } from './ToolbarEditor';
import type { ToolbarAction, ToolbarAlign } from '../../store/slices/toolbarSlice';

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
            ? 'bg-blue-600 text-white'
            : 'bg-gray-700 hover:bg-gray-600 text-gray-300'
        }`}
      >
        <Pencil size={12} />
        {toolbarEditMode ? 'Done' : 'Edit'}
      </button>
      {toolbarEditMode && (
        <>
          {/* Alignment buttons */}
          <div className="flex items-center border border-gray-600 rounded overflow-hidden">
            {(['left', 'center', 'right'] as ToolbarAlign[]).map((align) => {
              const Icon = align === 'left' ? AlignLeft : align === 'center' ? AlignCenter : AlignRight;
              return (
                <button
                  key={align}
                  onClick={() => setToolbarAlign(align)}
                  className={`p-1.5 transition-colors ${
                    toolbarAlign === align
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
          <button
            onClick={handleAddClick}
            className="px-2 py-1 text-xs bg-green-600 hover:bg-green-500 text-white rounded transition-colors flex items-center gap-1"
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

  const { sendCommand, connection, connectionState } = useReaper();
  const [editingAction, setEditingAction] = useState<ToolbarAction | null>(null);
  const [isAddingNew, setIsAddingNew] = useState(false);
  const [dragFromIndex, setDragFromIndex] = useState<number | null>(null);
  const [dragOverIndex, setDragOverIndex] = useState<number | null>(null);

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
    if (connectionState !== 'connected' || !connection) return;

    // Extract numeric commandIds from native REAPER action buttons (SWS/scripts excluded)
    const commandIds = toolbarActions
      .filter((a): a is ToolbarAction & { type: 'reaper_action' } => a.type === 'reaper_action')
      .filter((a) => a.actionId && !a.actionId.startsWith('_')) // Skip SWS/script actions
      .map((a) => parseInt(a.actionId, 10))
      .filter((id) => !isNaN(id));

    if (commandIds.length === 0) return;

    // Subscribe to toggle states and get initial snapshot
    const cmd = actionToggleState.subscribe(commandIds);
    connection
      .sendAsync(cmd.command, cmd.params)
      .then((response: unknown) => {
        const resp = response as { success?: boolean; payload?: { states?: Record<string, number> } };
        if (resp.success && resp.payload?.states) {
          updateToggleStates(resp.payload.states);
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

  const handleEditClick = useCallback((action: ToolbarAction) => {
    setEditingAction(action);
    setIsAddingNew(false);
  }, []);

  // Drag and drop handlers
  const handleDragStart = useCallback((index: number) => {
    setDragFromIndex(index);
  }, []);

  const handleDragOver = useCallback((index: number) => {
    setDragOverIndex(index);
  }, []);

  const handleDragEnd = useCallback(() => {
    if (dragFromIndex !== null && dragOverIndex !== null && dragFromIndex !== dragOverIndex) {
      reorderToolbarActions(dragFromIndex, dragOverIndex);
    }
    setDragFromIndex(null);
    setDragOverIndex(null);
  }, [dragFromIndex, dragOverIndex, reorderToolbarActions]);

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
              action.type === 'reaper_action' && action.actionId && !action.actionId.startsWith('_')
                ? toggleStates.get(parseInt(action.actionId, 10))
                : undefined
            }
            editMode={toolbarEditMode}
            onEdit={() => handleEditClick(action)}
            index={index}
            onDragStart={handleDragStart}
            onDragOver={handleDragOver}
            onDragEnd={handleDragEnd}
            isDragTarget={dragOverIndex === index && dragFromIndex !== index}
          />
        ))}
        {toolbarActions.length === 0 && (
          <div className="text-gray-500 text-sm py-4 px-2">
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
