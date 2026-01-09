/**
 * CuesModals - Modal components for playlist management
 */

import { useMemo, type ReactElement } from 'react';
import type { Region } from '../../../core/types';
import { reaperColorToHexWithFallback } from '../../../utils/color';
import { Modal, ModalContent, ModalFooter } from '../../../components/Modal';

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
    <Modal isOpen onClose={onCancel} title="Create Playlist" width="sm">
      <ModalContent>
        <input
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="Playlist name"
          className="w-full bg-bg-deep border border-border-subtle rounded-lg px-3 py-2 text-text-primary focus:outline-none focus:ring-2 focus:ring-focus-ring"
          autoFocus
          onKeyDown={(e) => {
            if (e.key === 'Enter' && value.trim()) onCreate();
          }}
        />
      </ModalContent>
      <ModalFooter
        onCancel={onCancel}
        onConfirm={onCreate}
        confirmText="Create"
        confirmDisabled={!value.trim()}
      />
    </Modal>
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
    <Modal isOpen onClose={onCancel} title="Rename Playlist" width="sm">
      <ModalContent>
        <input
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="Playlist name"
          className="w-full bg-bg-deep border border-border-subtle rounded-lg px-3 py-2 text-text-primary focus:outline-none focus:ring-2 focus:ring-focus-ring"
          autoFocus
          onKeyDown={(e) => {
            if (e.key === 'Enter' && value.trim()) onRename();
          }}
        />
      </ModalContent>
      <ModalFooter
        onCancel={onCancel}
        onConfirm={onRename}
        confirmText="Rename"
        confirmDisabled={!value.trim()}
      />
    </Modal>
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
    <Modal isOpen onClose={onCancel} title="Delete Playlist?" width="sm">
      <ModalContent>
        <p className="text-text-secondary">
          Are you sure you want to delete "{playlistName}"? This cannot be undone.
        </p>
      </ModalContent>
      <ModalFooter
        onCancel={onCancel}
        onConfirm={onDelete}
        confirmText="Delete"
        confirmVariant="danger"
      />
    </Modal>
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
      <Modal isOpen onClose={onClose} title="Add Region" width="lg">
        <ModalContent>
          <p className="text-text-secondary text-center">
            No regions in this project. Create regions in REAPER to add them here.
          </p>
        </ModalContent>
        <div className="px-4 py-3 border-t border-border-subtle">
          <button
            onClick={onClose}
            className="w-full py-2 bg-bg-elevated hover:bg-bg-hover rounded-lg transition-colors"
          >
            Close
          </button>
        </div>
      </Modal>
    );
  }

  return (
    <Modal isOpen onClose={onClose} title="Add Region" width="lg" className="max-h-[80vh] flex flex-col">
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
    </Modal>
  );
}
