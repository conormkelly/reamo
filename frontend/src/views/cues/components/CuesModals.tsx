/**
 * CuesModals - Modal components for playlist management
 */

import { useMemo, type ReactElement } from 'react';
import type { Region } from '../../../core/types';
import { reaperColorToHexWithFallback } from '../../../utils/color';

// Helper to format duration
function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

// =============================================================================
// CreatePlaylistModal
// =============================================================================

export interface CreatePlaylistModalProps {
  value: string;
  onChange: (value: string) => void;
  onCreate: () => void;
  onCancel: () => void;
}

export function CreatePlaylistModal({ value, onChange, onCreate, onCancel }: CreatePlaylistModalProps): ReactElement {
  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onCancel}>
      <div className="bg-bg-surface rounded-lg p-4 w-full max-w-sm" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-semibold mb-4">Create Playlist</h3>
        <input
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="Playlist name"
          className="w-full bg-bg-deep border border-border-subtle rounded-lg px-3 py-2 text-text-primary mb-4 focus:outline-none focus:ring-2 focus:ring-focus-ring"
          autoFocus
          onKeyDown={(e) => {
            if (e.key === 'Enter') onCreate();
            if (e.key === 'Escape') onCancel();
          }}
        />
        <div className="flex gap-2">
          <button
            onClick={onCancel}
            className="flex-1 py-2 bg-bg-elevated hover:bg-bg-hover rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={onCreate}
            disabled={!value.trim()}
            className="flex-1 py-2 bg-primary hover:bg-primary-hover disabled:bg-bg-elevated disabled:text-text-muted rounded-lg transition-colors"
          >
            Create
          </button>
        </div>
      </div>
    </div>
  );
}

// =============================================================================
// RenamePlaylistModal
// =============================================================================

export interface RenamePlaylistModalProps {
  value: string;
  onChange: (value: string) => void;
  onRename: () => void;
  onCancel: () => void;
}

export function RenamePlaylistModal({ value, onChange, onRename, onCancel }: RenamePlaylistModalProps): ReactElement {
  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onCancel}>
      <div className="bg-bg-surface rounded-lg p-4 w-full max-w-sm" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-semibold mb-4">Rename Playlist</h3>
        <input
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="Playlist name"
          className="w-full bg-bg-deep border border-border-subtle rounded-lg px-3 py-2 text-text-primary mb-4 focus:outline-none focus:ring-2 focus:ring-focus-ring"
          autoFocus
          onKeyDown={(e) => {
            if (e.key === 'Enter') onRename();
            if (e.key === 'Escape') onCancel();
          }}
        />
        <div className="flex gap-2">
          <button
            onClick={onCancel}
            className="flex-1 py-2 bg-bg-elevated hover:bg-bg-hover rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={onRename}
            disabled={!value.trim()}
            className="flex-1 py-2 bg-primary hover:bg-primary-hover disabled:bg-bg-elevated disabled:text-text-muted rounded-lg transition-colors"
          >
            Rename
          </button>
        </div>
      </div>
    </div>
  );
}

// =============================================================================
// DeletePlaylistModal
// =============================================================================

export interface DeletePlaylistModalProps {
  playlistName: string;
  onDelete: () => void;
  onCancel: () => void;
}

export function DeletePlaylistModal({ playlistName, onDelete, onCancel }: DeletePlaylistModalProps): ReactElement {
  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onCancel}>
      <div className="bg-bg-surface rounded-lg p-4 w-full max-w-sm" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-semibold mb-2">Delete Playlist?</h3>
        <p className="text-text-secondary mb-4">
          Are you sure you want to delete "{playlistName}"? This cannot be undone.
        </p>
        <div className="flex gap-2">
          <button
            onClick={onCancel}
            className="flex-1 py-2 bg-bg-elevated hover:bg-bg-hover rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={onDelete}
            className="flex-1 py-2 bg-error-action hover:bg-error rounded-lg transition-colors"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
  );
}

// =============================================================================
// RegionPickerModal
// =============================================================================

export interface RegionPickerModalProps {
  regions: Region[];
  regionIdsInPlaylist: Set<number>;
  onAdd: (regionId: number) => void;
  onAddAll: () => void;
  onClose: () => void;
}

export function RegionPickerModal({
  regions,
  regionIdsInPlaylist,
  onAdd,
  onAddAll,
  onClose,
}: RegionPickerModalProps): ReactElement {
  const sortedRegions = useMemo(
    () => [...regions].sort((a, b) => a.start - b.start),
    [regions]
  );

  if (regions.length === 0) {
    return (
      <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onClose}>
        <div className="bg-bg-surface rounded-lg p-4 w-full max-w-md" onClick={(e) => e.stopPropagation()}>
          <h3 className="text-lg font-semibold mb-4">Add Region</h3>
          <p className="text-text-secondary mb-4 text-center">
            No regions in this project. Create regions in REAPER to add them here.
          </p>
          <button
            onClick={onClose}
            className="w-full py-2 bg-bg-elevated hover:bg-bg-hover rounded-lg transition-colors"
          >
            Close
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onClose}>
      <div
        className="bg-bg-surface rounded-lg w-full max-w-md max-h-[80vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="p-4 border-b border-border-subtle">
          <h3 className="text-lg font-semibold">Add Region</h3>
        </div>

        {/* Add All button */}
        <div className="p-3 border-b border-border-subtle">
          <button
            onClick={onAddAll}
            className="w-full py-2 bg-primary hover:bg-primary-hover rounded-lg font-medium transition-colors"
          >
            Add All Regions ({regions.length})
          </button>
        </div>

        {/* Region list */}
        <div className="flex-1 overflow-auto p-3">
          <div className="space-y-2">
            {sortedRegions.map((region) => {
              const inPlaylist = regionIdsInPlaylist.has(region.id);
              const color = reaperColorToHexWithFallback(region.color, 'var(--color-text-muted)');

              return (
                <button
                  key={region.id}
                  onClick={() => {
                    onAdd(region.id);
                  }}
                  className="w-full flex items-center gap-3 p-3 bg-bg-elevated hover:bg-bg-hover rounded-lg transition-colors text-left"
                >
                  <div
                    className="w-1.5 h-8 rounded-full flex-none"
                    style={{ backgroundColor: color }}
                  />
                  <div className="flex-1 min-w-0">
                    <div className="font-medium truncate">{region.name}</div>
                    <div className="text-sm text-text-secondary">
                      {formatDuration(region.end - region.start)}
                    </div>
                  </div>
                  {inPlaylist && (
                    <span className="text-text-muted text-sm">In list</span>
                  )}
                </button>
              );
            })}
          </div>
        </div>

        <div className="p-3 border-t border-border-subtle">
          <button
            onClick={onClose}
            className="w-full py-2 bg-bg-elevated hover:bg-bg-hover rounded-lg transition-colors"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
