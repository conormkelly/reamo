/**
 * Region Edit Action Bar Component
 * Shows Save/Cancel buttons when there are pending region changes
 */

import { useCallback, type ReactElement } from 'react';
import { Save, X, Loader2, AlertCircle, Undo2, Redo2 } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { region, type RegionBatchOp } from '../../core/WebSocketCommands';

export function RegionEditActionBar(): ReactElement | null {
  const { connection } = useReaper();
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

  // Build the batch ops array from pending changes
  const buildBatchOps = useCallback((): RegionBatchOp[] => {
    const ops: RegionBatchOp[] = [];

    for (const [keyStr, change] of Object.entries(pendingChanges)) {
      const key = parseInt(keyStr, 10);

      if (change.isDeleted) {
        ops.push({ op: 'delete', id: change.originalIdx });
      } else if (change.isNew) {
        ops.push({
          op: 'create',
          start: change.newStart,
          end: change.newEnd,
          name: change.name,
          color: change.color ?? 0,
        });
      } else {
        // Check what changed - look up by region ID, not array index
        const originalRegion = regions.find(r => r.id === key);
        if (!originalRegion) continue;

        const startChanged = Math.abs(change.newStart - change.originalStart) > 0.001;
        const endChanged = Math.abs(change.newEnd - change.originalEnd) > 0.001;
        const nameChanged = change.name !== originalRegion.name;
        const colorChanged = change.color !== undefined && change.color !== originalRegion.color;

        if (startChanged || endChanged || nameChanged || colorChanged) {
          ops.push({
            op: 'update',
            id: change.originalIdx,
            start: change.newStart,
            end: change.newEnd,
            name: change.name,
            color: change.color ?? originalRegion.color ?? 0,
          });
        }
      }
    }

    return ops;
  }, [pendingChanges, regions]);

  // Handle save
  const handleSave = useCallback(async () => {
    if (!hasPendingChanges()) return;

    setCommitting(true);
    setCommitError(null);

    try {
      const ops = buildBatchOps();
      if (ops.length === 0) {
        commitChanges();
        return;
      }

      // Send batch command and wait for response
      const cmd = region.batch(ops);
      if (!connection) {
        throw new Error('Not connected to REAPER');
      }
      const response = await connection.sendAsync(cmd.command, cmd.params);

      // Check for warnings in response
      const resp = response as { applied?: number; skipped?: number; warnings?: string[] } | undefined;
      if (resp?.skipped && resp.skipped > 0 && resp.warnings?.length) {
        console.warn('Region batch warnings:', resp.warnings);
      }

      // Success - commit local changes
      commitChanges();
    } catch (err) {
      setCommitting(false);
      setCommitError(err instanceof Error ? err.message : 'Unknown error');
    }
  }, [
    hasPendingChanges,
    buildBatchOps,
    connection,
    commitChanges,
    setCommitting,
    setCommitError,
  ]);

  // Handle cancel
  const handleCancel = useCallback(() => {
    cancelChanges();
  }, [cancelChanges]);

  // Don't show if no pending changes
  if (!hasPendingChanges()) {
    return null;
  }

  return (
    <div className="flex items-center justify-between px-3 py-2 bg-pending-bg border border-pending-border rounded-lg">
      <div className="flex items-center gap-2">
        {commitError ? (
          <AlertCircle size={16} className="text-error-text" />
        ) : (
          <div className="w-2 h-2 bg-pending-dot rounded-full animate-pulse" />
        )}
        <span className="text-sm text-pending-text">
          {commitError ? (
            <span className="text-error-text">{commitError}</span>
          ) : isCommitting ? (
            'Saving changes...'
          ) : (
            `Unsaved changes`
          )}
        </span>
      </div>

      <div className="flex items-center gap-2">
        {/* Undo/Redo buttons */}
        <div className="flex items-center gap-1 mr-2">
          <button
            onClick={() => undo()}
            disabled={!canUndo() || isCommitting || isDragging}
            className="flex items-center justify-center w-8 h-8 text-text-tertiary bg-bg-elevated hover:bg-bg-hover rounded transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            title="Undo"
          >
            <Undo2 size={16} />
          </button>
          <button
            onClick={() => redo()}
            disabled={!canRedo() || isCommitting || isDragging}
            className="flex items-center justify-center w-8 h-8 text-text-tertiary bg-bg-elevated hover:bg-bg-hover rounded transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            title="Redo"
          >
            <Redo2 size={16} />
          </button>
        </div>

        <button
          onClick={handleCancel}
          disabled={isCommitting}
          className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-text-tertiary bg-bg-elevated hover:bg-bg-hover rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <X size={14} />
          Cancel
        </button>
        <button
          onClick={handleSave}
          disabled={isCommitting}
          className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-text-on-success bg-success-action hover:bg-success rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isCommitting ? (
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
