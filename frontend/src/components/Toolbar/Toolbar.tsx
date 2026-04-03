/**
 * Toolbar - User-configurable action buttons
 * Horizontal scrollable button bar with edit mode
 * Collapse is now handled by parent CollapsibleSection wrapper
 */

import { useEffect, useCallback, useState, useRef, type ReactElement } from 'react';
import { Plus, Pencil } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useListReorder } from '../../hooks';
import { actionToggleState } from '../../core/WebSocketCommands';
import { ToolbarButton, type ToolbarLayout } from './ToolbarButton';
import { ToolbarEditor } from './ToolbarEditor';
import type { ToolbarAction, ToggleStateEntry, NameToIdEntry } from '../../store/slices/toolbarSlice';
import { makeToggleKey } from '../../store/slices/toolbarSlice';

/** Horizontal mode: single row with 4 slots per page */
const HORIZONTAL_SLOTS = 4;
/** Swipe threshold in pixels to trigger page change */
const SWIPE_THRESHOLD = 50;

interface ToolbarProps {
  /** Layout mode - horizontal (footer), vertical (side rail), or grid (full screen) */
  layout?: ToolbarLayout;
}

/**
 * Header controls for Toolbar section (Edit/Add buttons)
 * Passed as headerControls to CollapsibleSection
 * Note: Alignment options removed - fixed 4×2 grid doesn't need alignment
 */
export function ToolbarHeaderControls(): ReactElement {
  const {
    toolbarEditMode,
    setToolbarEditMode,
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
        <button
          onClick={handleAddClick}
          className="px-2 py-1 text-xs bg-success-action hover:bg-success text-text-on-success rounded transition-colors flex items-center gap-1"
        >
          <Plus size={12} />
          Add
        </button>
      )}
    </div>
  );
}

export function Toolbar({ layout = 'horizontal' }: ToolbarProps): ReactElement {
  const {
    toolbarActions,
    toolbarEditMode,
    toolbarCurrentPage,
    toggleStates,
    loadToolbarFromStorage,
    addToolbarAction,
    updateToolbarAction,
    removeToolbarAction,
    reorderToolbarActions,
    updateToggleStates,
    setToolbarCurrentPage,
  } = useReaperStore();

  const { sendCommand, sendAsync, connectionStatus } = useReaper();
  const [editingAction, setEditingAction] = useState<ToolbarAction | null>(null);
  const [isAddingNew, setIsAddingNew] = useState(false);

  // Swipe handling for page navigation
  const touchStartX = useRef<number | null>(null);
  const touchStartY = useRef<number | null>(null);
  const isSwiping = useRef(false);

  // Compute pagination - only for horizontal mode
  // Vertical mode shows all actions in a scrollable list (no paging)
  const slotsPerPage = layout === 'horizontal' ? HORIZONTAL_SLOTS : toolbarActions.length;
  const totalPages = layout === 'vertical' ? 1 : Math.max(1, Math.ceil(toolbarActions.length / slotsPerPage));
  const currentPage = Math.min(toolbarCurrentPage, totalPages - 1);
  const startIndex = layout === 'vertical' ? 0 : currentPage * slotsPerPage;
  const pageActions = layout === 'vertical'
    ? toolbarActions
    : toolbarActions.slice(startIndex, startIndex + slotsPerPage);

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

  // Swipe gesture handlers for page navigation (horizontal mode only)
  const handleTouchStart = useCallback((e: React.TouchEvent) => {
    // Don't capture swipe if we're in edit mode (allow drag reorder) or not horizontal
    if (toolbarEditMode || layout !== 'horizontal') return;
    touchStartX.current = e.touches[0].clientX;
    touchStartY.current = e.touches[0].clientY;
    isSwiping.current = false;
  }, [toolbarEditMode, layout]);

  const handleTouchMove = useCallback((e: React.TouchEvent) => {
    if (touchStartX.current === null || touchStartY.current === null) return;

    const deltaX = e.touches[0].clientX - touchStartX.current;
    const deltaY = e.touches[0].clientY - touchStartY.current;

    // Only consider it a swipe if horizontal movement > vertical
    if (Math.abs(deltaX) > Math.abs(deltaY) && Math.abs(deltaX) > 10) {
      isSwiping.current = true;
    }
  }, []);

  const handleTouchEnd = useCallback((e: React.TouchEvent) => {
    if (touchStartX.current === null || !isSwiping.current) {
      touchStartX.current = null;
      touchStartY.current = null;
      return;
    }

    const deltaX = e.changedTouches[0].clientX - touchStartX.current;

    if (Math.abs(deltaX) > SWIPE_THRESHOLD) {
      if (deltaX < 0 && currentPage < totalPages - 1) {
        // Swipe left → next page
        setToolbarCurrentPage(currentPage + 1);
      } else if (deltaX > 0 && currentPage > 0) {
        // Swipe right → previous page
        setToolbarCurrentPage(currentPage - 1);
      }
    }

    touchStartX.current = null;
    touchStartY.current = null;
    isSwiping.current = false;
  }, [currentPage, totalPages, setToolbarCurrentPage]);

  // Page indicator click handler
  const handlePageIndicatorClick = useCallback(() => {
    // Cycle to next page
    setToolbarCurrentPage((currentPage + 1) % totalPages);
  }, [currentPage, totalPages, setToolbarCurrentPage]);

  // Create slots array with actions + empty slots to fill grid (horizontal mode only)
  // Vertical mode doesn't need empty slots (scrollable list)
  const slots: (ToolbarAction | null)[] = [...pageActions];
  if (layout === 'horizontal') {
    while (slots.length < HORIZONTAL_SLOTS) {
      slots.push(null);
    }
  }

  // Render button with common props
  const renderButton = (action: ToolbarAction, absoluteIndex: number) => (
    <ToolbarButton
      key={action.id}
      action={action}
      layout={layout}
      toggleState={
        action.type === 'reaper_action' && action.actionId
          ? toggleStates.get(makeToggleKey(action.sectionId, action.actionId))
          : undefined
      }
      editMode={toolbarEditMode}
      onEdit={() => handleEditClick(action)}
      dragProps={getDragItemProps(absoluteIndex)}
      isDragTarget={isDragTarget(absoluteIndex)}
    />
  );

  // Vertical layout: single column, scrollable
  if (layout === 'vertical') {
    return (
      <>
        <div className="flex flex-col gap-2 overflow-y-auto h-full p-1">
          {toolbarActions.map((action, index) => renderButton(action, index))}

          {/* Empty state hint - only in edit mode */}
          {toolbarActions.length === 0 && toolbarEditMode && (
            <div className="flex items-center justify-center text-text-muted text-sm py-4">
              Tap &ldquo;+&rdquo; above to add a button
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

  // Horizontal layout: single row with 4 slots, swipe paging
  return (
    <>
      <div
        className="flex flex-col h-full"
        onTouchStart={handleTouchStart}
        onTouchMove={handleTouchMove}
        onTouchEnd={handleTouchEnd}
      >
        {/* Grid container - single row of 4 columns */}
        <div
          className="grid gap-1 flex-1 p-1"
          style={{
            gridTemplateColumns: `repeat(${HORIZONTAL_SLOTS}, 1fr)`,
            gridTemplateRows: '1fr',  // Single row fills height
          }}
        >
          {slots.map((action, slotIndex) => {
            // Calculate absolute index for drag reorder
            const absoluteIndex = startIndex + slotIndex;

            if (action) {
              return renderButton(action, absoluteIndex);
            }

            // Empty slot
            return (
              <div
                key={`empty-${slotIndex}`}
                className={`rounded-lg ${
                  toolbarEditMode
                    ? 'border-2 border-dashed border-border-subtle'
                    : ''
                }`}
              />
            );
          })}
        </div>

        {/* Page indicator (only show if multiple pages) */}
        {totalPages > 1 && (
          <button
            onClick={handlePageIndicatorClick}
            className="text-xs text-text-tertiary py-0.5 hover:text-text-secondary transition-colors"
          >
            {currentPage + 1}/{totalPages}
          </button>
        )}

        {/* Empty state hint - only in edit mode */}
        {toolbarActions.length === 0 && toolbarEditMode && (
          <div className="absolute inset-0 flex items-center justify-center text-text-muted text-sm pointer-events-none">
            Tap &ldquo;+&rdquo; above to add a button
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
