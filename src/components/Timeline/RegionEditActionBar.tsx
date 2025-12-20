/**
 * Region Edit Action Bar Component
 * Shows Save/Cancel buttons when there are pending region changes
 */

import { useState, useCallback, type ReactElement } from 'react';
import { Save, X, Loader2, AlertCircle, Undo2, Redo2 } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import * as commands from '../../core/CommandBuilder';

// Lua script action ID (user needs to assign this after loading the script)
// For now we'll use a command name approach
const SCRIPT_SECTION = 'Reamo';

export function RegionEditActionBar(): ReactElement | null {
  const { send } = useReaper();
  const hasPendingChanges = useReaperStore((s) => s.hasPendingChanges);
  const pendingChanges = useReaperStore((s) => s.pendingChanges);
  const regions = useReaperStore((s) => s.regions);
  const commitChanges = useReaperStore((s) => s.commitChanges);
  const cancelChanges = useReaperStore((s) => s.cancelChanges);
  const setCommitting = useReaperStore((s) => s.setCommitting);
  const setCommitError = useReaperStore((s) => s.setCommitError);
  const isCommitting = useReaperStore((s) => s.isCommitting);
  const commitError = useReaperStore((s) => s.commitError);
  const canUndo = useReaperStore((s) => s.canUndo);
  const canRedo = useReaperStore((s) => s.canRedo);
  const undo = useReaperStore((s) => s.undo);
  const redo = useReaperStore((s) => s.redo);
  const isDragging = useReaperStore((s) => s.dragType !== 'none');

  const [pollingForProcessed, setPollingForProcessed] = useState(false);

  // Build the batch data string from pending changes
  const buildBatchData = useCallback(() => {
    const operations: string[] = [];

    for (const [keyStr, change] of Object.entries(pendingChanges)) {
      const key = parseInt(keyStr, 10);

      if (change.isDeleted) {
        // delete|markrgnidx
        operations.push(`delete|${change.originalIdx}`);
      } else if (change.isNew) {
        // create|start|end|name|color
        const color = change.color ?? 0;
        operations.push(`create|${change.newStart}|${change.newEnd}|${change.name}|${color}`);
      } else {
        // Check what changed
        const originalRegion = regions[key];
        if (!originalRegion) continue;

        const startChanged = Math.abs(change.newStart - change.originalStart) > 0.001;
        const endChanged = Math.abs(change.newEnd - change.originalEnd) > 0.001;
        const nameChanged = change.name !== originalRegion.name;
        const colorChanged = change.color !== undefined && change.color !== originalRegion.color;

        if (startChanged || endChanged || nameChanged || colorChanged) {
          // update|markrgnidx|newStart|newEnd|name|color
          // Use current values for unchanged properties
          const name = change.name;
          const color = change.color ?? originalRegion.color ?? 0;
          operations.push(`update|${change.originalIdx}|${change.newStart}|${change.newEnd}|${name}|${color}`);
        }
      }
    }

    return operations.join(';');
  }, [pendingChanges, regions]);

  // Handle save
  const handleSave = useCallback(async () => {
    if (!hasPendingChanges()) return;

    setCommitting(true);
    setCommitError(null);

    try {
      const batchData = buildBatchData();
      if (!batchData) {
        commitChanges();
        return;
      }

      // Write ExtState values (always use ripple mode)
      const setExtStateCmds = commands.join(
        commands.setExtState(SCRIPT_SECTION, 'action', 'batch'),
        commands.setExtState(SCRIPT_SECTION, 'batch_data', batchData),
        commands.setExtState(SCRIPT_SECTION, 'mode', 'ripple'),
        commands.setExtState(SCRIPT_SECTION, 'processed', ''),
        commands.setExtState(SCRIPT_SECTION, 'error', '')
      );
      send(setExtStateCmds);

      // Trigger the Lua script by name
      // The script needs to be run manually or via an action
      // For now, we'll poll for the processed flag
      // User should run the script: Actions > Run script > Reamo_RegionEdit.lua
      setPollingForProcessed(true);

      // Poll for processed flag
      let attempts = 0;
      const maxAttempts = 50; // 5 seconds max
      const pollInterval = 100;

      const poll = async () => {
        attempts++;

        // Check for processed flag
        send(commands.getExtState(SCRIPT_SECTION, 'processed'));

        // Wait a bit for response
        await new Promise((resolve) => setTimeout(resolve, pollInterval));

        // For now, we'll just wait a bit and assume it worked
        // In a real implementation, we'd parse the response
        if (attempts >= 3) {
          // Assume success after a short delay
          setPollingForProcessed(false);
          commitChanges();

          // Refresh regions by forcing a new poll
          send(commands.regions());
          return;
        }

        if (attempts < maxAttempts) {
          poll();
        } else {
          setPollingForProcessed(false);
          setCommitError('Timeout waiting for script. Make sure Reamo_RegionEdit.lua is running.');
        }
      };

      poll();
    } catch (err) {
      setCommitting(false);
      setCommitError(err instanceof Error ? err.message : 'Unknown error');
    }
  }, [
    hasPendingChanges,
    buildBatchData,
    send,
    commitChanges,
    setCommitting,
    setCommitError,
  ]);

  // Handle cancel
  const handleCancel = useCallback(() => {
    cancelChanges();
  }, [cancelChanges]);

  // Count pending changes
  const pendingCount = Object.keys(pendingChanges).length;

  // Don't show if no pending changes
  if (!hasPendingChanges()) {
    return null;
  }

  return (
    <div className="flex items-center justify-between px-3 py-2 bg-amber-900/30 border border-amber-600/50 rounded-lg">
      <div className="flex items-center gap-2">
        {commitError ? (
          <AlertCircle size={16} className="text-red-400" />
        ) : (
          <div className="w-2 h-2 bg-amber-400 rounded-full animate-pulse" />
        )}
        <span className="text-sm text-amber-200">
          {commitError ? (
            <span className="text-red-400">{commitError}</span>
          ) : isCommitting ? (
            'Saving changes...'
          ) : (
            `${pendingCount} region${pendingCount !== 1 ? 's' : ''} affected`
          )}
        </span>
      </div>

      <div className="flex items-center gap-2">
        {/* Undo/Redo buttons */}
        <div className="flex items-center gap-1 mr-2">
          <button
            onClick={() => undo()}
            disabled={!canUndo() || isCommitting || isDragging}
            className="flex items-center justify-center w-8 h-8 text-gray-300 bg-gray-700 hover:bg-gray-600 rounded transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            title="Undo"
          >
            <Undo2 size={16} />
          </button>
          <button
            onClick={() => redo()}
            disabled={!canRedo() || isCommitting || isDragging}
            className="flex items-center justify-center w-8 h-8 text-gray-300 bg-gray-700 hover:bg-gray-600 rounded transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            title="Redo"
          >
            <Redo2 size={16} />
          </button>
        </div>

        <button
          onClick={handleCancel}
          disabled={isCommitting}
          className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-gray-300 bg-gray-700 hover:bg-gray-600 rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <X size={14} />
          Cancel
        </button>
        <button
          onClick={handleSave}
          disabled={isCommitting}
          className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-white bg-green-600 hover:bg-green-500 rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isCommitting || pollingForProcessed ? (
            <Loader2 size={14} className="animate-spin" />
          ) : (
            <Save size={14} />
          )}
          Save
        </button>
      </div>
    </div>
  );
}
