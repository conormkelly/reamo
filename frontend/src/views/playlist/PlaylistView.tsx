/**
 * PlaylistView - Playlist management and playback
 * Build playlists from regions with loop counts for live performance
 */

import { useState, useEffect, useRef, useCallback, useMemo, type ReactElement } from 'react';
import {
  Plus,
  Pencil,
  Trash2,
  Play,
  Pause,
  Square,
  SkipBack,
  SkipForward,
  ArrowRightFromLine,
  Move,
  ListMusic,
} from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../../components/ReaperProvider';
import { ViewHeader, ViewLayout } from '../../components';
import { playlist as playlistCmd } from '../../core/WebSocketCommands';
import type { WSPlaylist } from '../../core/WebSocketTypes';
import type { Region } from '../../core/types';
import { useUIPreferences } from '../../hooks';
import {
  PlaylistEntryRow,
  CreatePlaylistModal,
  RenamePlaylistModal,
  DeletePlaylistModal,
  RegionPickerModal,
} from './components';

// Fixed heights for bottom bar calculations
const TAB_BAR_HEIGHT = 48;
const PERSISTENT_TRANSPORT_HEIGHT = 56;
const PLAYBACK_CONTROLS_HEIGHT = 80;

// Helper to get region by ID
function getRegionById(regions: Region[], regionId: number): Region | undefined {
  return regions.find((r) => r.id === regionId);
}

export function PlaylistView(): ReactElement {
  const { sendCommand } = useReaper();
  const { showTabBar, showPersistentTransport } = useUIPreferences();

  // Calculate bottom offset for fixed playback controls
  const bottomOffset =
    (showTabBar ? TAB_BAR_HEIGHT : 0) +
    (showPersistentTransport ? PERSISTENT_TRANSPORT_HEIGHT : 0);

  // Store state
  const playlists = useReaperStore((s) => s.playlists);
  const regions = useReaperStore((s) => s.regions);
  const activePlaylistIndex = useReaperStore((s) => s.activePlaylistIndex);
  const currentEntryIndex = useReaperStore((s) => s.currentEntryIndex);
  const loopsRemaining = useReaperStore((s) => s.loopsRemaining);
  const currentLoopIteration = useReaperStore((s) => s.currentLoopIteration);
  const isPlaylistActive = useReaperStore((s) => s.isPlaylistActive);
  const isPaused = useReaperStore((s) => s.isPaused);
  const advanceAfterLoop = useReaperStore((s) => s.advanceAfterLoop);

  // Local state
  const [selectedPlaylistIdx, setSelectedPlaylistIdx] = useState<number>(0);
  const [selectedEntryIdx, setSelectedEntryIdx] = useState<number | null>(null);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [showRenameModal, setShowRenameModal] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const [showRegionPicker, setShowRegionPicker] = useState(false);
  const [newPlaylistName, setNewPlaylistName] = useState('');
  const [reorderMode, setReorderMode] = useState(false);

  // Drag-drop state
  const [draggedIdx, setDraggedIdx] = useState<number | null>(null);
  const [dropTargetIdx, setDropTargetIdx] = useState<number | null>(null);

  // Touch drag refs
  const touchStartY = useRef<number>(0);
  const touchCurrentY = useRef<number>(0);

  // Ref for autoscroll
  const entryRefs = useRef<Map<number, HTMLDivElement>>(new Map());

  // Sync selected playlist with active when playing
  useEffect(() => {
    if (isPlaylistActive && activePlaylistIndex !== null) {
      setSelectedPlaylistIdx(activePlaylistIndex);
    }
  }, [isPlaylistActive, activePlaylistIndex]);

  // Autoscroll to current entry during playback
  useEffect(() => {
    if (isPlaylistActive && currentEntryIndex !== null) {
      const entryEl = entryRefs.current.get(currentEntryIndex);
      if (entryEl) {
        entryEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }
    }
  }, [isPlaylistActive, currentEntryIndex]);

  // Current playlist
  const currentPlaylist: WSPlaylist | null = playlists[selectedPlaylistIdx] ?? null;

  // Handlers
  const handleCreatePlaylist = useCallback(() => {
    if (newPlaylistName.trim()) {
      sendCommand(playlistCmd.create(newPlaylistName.trim()));
      // Auto-switch to the new playlist (it will be appended at the end)
      setSelectedPlaylistIdx(playlists.length);
      setNewPlaylistName('');
      setShowCreateModal(false);
    }
  }, [newPlaylistName, sendCommand, playlists.length]);

  const handleRenamePlaylist = useCallback(() => {
    if (newPlaylistName.trim() && currentPlaylist) {
      sendCommand(playlistCmd.rename(selectedPlaylistIdx, newPlaylistName.trim()));
      setNewPlaylistName('');
      setShowRenameModal(false);
    }
  }, [newPlaylistName, selectedPlaylistIdx, currentPlaylist, sendCommand]);

  const handleDeletePlaylist = useCallback(() => {
    sendCommand(playlistCmd.delete(selectedPlaylistIdx));
    setShowDeleteModal(false);
    // Select first remaining playlist or none
    if (selectedPlaylistIdx > 0) {
      setSelectedPlaylistIdx(selectedPlaylistIdx - 1);
    }
  }, [selectedPlaylistIdx, sendCommand]);

  const handleAddRegion = useCallback(
    (regionId: number) => {
      sendCommand(playlistCmd.addEntry(selectedPlaylistIdx, regionId, 1));
    },
    [selectedPlaylistIdx, sendCommand]
  );

  const handleAddAllRegions = useCallback(() => {
    // Add all regions sorted by start time
    const sortedRegions = [...regions].sort((a, b) => a.start - b.start);
    for (const region of sortedRegions) {
      sendCommand(playlistCmd.addEntry(selectedPlaylistIdx, region.id, 1));
    }
    setShowRegionPicker(false);
  }, [regions, selectedPlaylistIdx, sendCommand]);

  const handleRemoveEntry = useCallback(
    (entryIdx: number) => {
      sendCommand(playlistCmd.removeEntry(selectedPlaylistIdx, entryIdx));
    },
    [selectedPlaylistIdx, sendCommand]
  );

  const handleSetLoopCount = useCallback(
    (entryIdx: number, loopCount: number) => {
      sendCommand(playlistCmd.setLoopCount(selectedPlaylistIdx, entryIdx, loopCount));
    },
    [selectedPlaylistIdx, sendCommand]
  );

  const handlePlay = useCallback(() => {
    if (selectedEntryIdx !== null) {
      // Play from selected entry
      sendCommand(playlistCmd.playFromEntry(selectedPlaylistIdx, selectedEntryIdx));
      setSelectedEntryIdx(null); // Clear selection after starting
    } else {
      // Play from beginning or resume
      sendCommand(playlistCmd.play(selectedPlaylistIdx));
    }
  }, [selectedPlaylistIdx, selectedEntryIdx, sendCommand]);

  const handlePlayFromEntry = useCallback(
    (entryIdx: number) => {
      sendCommand(playlistCmd.playFromEntry(selectedPlaylistIdx, entryIdx));
    },
    [selectedPlaylistIdx, sendCommand]
  );

  const handlePause = useCallback(() => {
    sendCommand(playlistCmd.pause());
  }, [sendCommand]);

  const handleStop = useCallback(() => {
    sendCommand(playlistCmd.stop());
  }, [sendCommand]);

  const handleNext = useCallback(() => {
    sendCommand(playlistCmd.next());
  }, [sendCommand]);

  const handlePrev = useCallback(() => {
    sendCommand(playlistCmd.prev());
  }, [sendCommand]);

  const handleAdvanceAfterLoop = useCallback(() => {
    sendCommand(playlistCmd.advanceAfterLoop());
  }, [sendCommand]);

  const handleSelectEntry = useCallback((idx: number) => {
    // Toggle selection - tap again to deselect
    setSelectedEntryIdx((prev) => (prev === idx ? null : idx));
  }, []);

  // Drag-drop handlers
  const handleDragStart = useCallback((idx: number) => {
    setDraggedIdx(idx);
  }, []);

  const handleDragOver = useCallback((e: React.DragEvent, idx: number) => {
    e.preventDefault();
    if (draggedIdx === null || draggedIdx === idx) return;
    setDropTargetIdx(idx);
  }, [draggedIdx]);

  const handleDragEnd = useCallback(() => {
    setDraggedIdx(null);
    setDropTargetIdx(null);
  }, []);

  const handleDrop = useCallback((targetIdx: number) => {
    if (draggedIdx === null || draggedIdx === targetIdx) {
      setDraggedIdx(null);
      setDropTargetIdx(null);
      return;
    }
    sendCommand(playlistCmd.reorderEntry(selectedPlaylistIdx, draggedIdx, targetIdx));
    setDraggedIdx(null);
    setDropTargetIdx(null);
  }, [draggedIdx, selectedPlaylistIdx, sendCommand]);

  // Touch handlers for mobile drag-drop
  const handleTouchStart = useCallback((e: React.TouchEvent, idx: number) => {
    touchStartY.current = e.touches[0].clientY;
    touchCurrentY.current = e.touches[0].clientY;
    setDraggedIdx(idx);
  }, []);

  const handleTouchMove = useCallback((e: React.TouchEvent) => {
    if (draggedIdx === null || !currentPlaylist) return;

    touchCurrentY.current = e.touches[0].clientY;
    const deltaY = touchCurrentY.current - touchStartY.current;

    // Calculate which item we're over based on touch position
    const itemHeight = 72; // Approximate height of each entry row
    const itemsMoved = Math.round(deltaY / itemHeight);
    const newIndex = Math.max(0, Math.min(currentPlaylist.entries.length - 1, draggedIdx + itemsMoved));

    setDropTargetIdx(newIndex);
  }, [draggedIdx, currentPlaylist]);

  const handleTouchEnd = useCallback(() => {
    if (draggedIdx === null || dropTargetIdx === null || draggedIdx === dropTargetIdx) {
      setDraggedIdx(null);
      setDropTargetIdx(null);
      return;
    }

    sendCommand(playlistCmd.reorderEntry(selectedPlaylistIdx, draggedIdx, dropTargetIdx));
    setDraggedIdx(null);
    setDropTargetIdx(null);
  }, [draggedIdx, dropTargetIdx, selectedPlaylistIdx, sendCommand]);

  // Check if a region is already in the current playlist
  const regionIdsInPlaylist = useMemo(() => {
    if (!currentPlaylist) return new Set<number>();
    return new Set(currentPlaylist.entries.map((e) => e.regionId));
  }, [currentPlaylist]);

  // No playlists empty state
  if (playlists.length === 0) {
    return (
      <ViewLayout
        viewId="playlist"
        className="bg-bg-app text-text-primary p-view"
        header={<ViewHeader currentView="playlist" />}
      >
        {/* Empty state content - centered in available space */}
        <div className="h-full flex flex-col items-center justify-center text-center">
          <ListMusic size={48} className="text-text-disabled mb-4" />
          <h2 className="text-xl font-medium text-text-tertiary mb-2">No Playlists Yet</h2>
          <p className="text-text-muted mb-6 max-w-xs">
            Practice, perform, or explore new arrangements using project regions. Adjust loop counts per region on the fly.
          </p>
          <button
            onClick={() => setShowCreateModal(true)}
            className="flex items-center gap-2 px-4 py-2 bg-primary text-text-on-primary rounded-lg hover:bg-primary-hover transition-colors"
          >
            <Plus size={18} />
            <span>Create Playlist</span>
          </button>
        </div>

        {/* Create Modal */}
        {showCreateModal && (
          <CreatePlaylistModal
            value={newPlaylistName}
            onChange={setNewPlaylistName}
            onCreate={handleCreatePlaylist}
            onCancel={() => {
              setShowCreateModal(false);
              setNewPlaylistName('');
            }}
          />
        )}
      </ViewLayout>
    );
  }

  // Header content with playlist controls
  const headerContent = (
    <ViewHeader currentView="playlist">
      {/* Playlist selector */}
      <select
        value={selectedPlaylistIdx}
        onChange={(e) => {
          setSelectedPlaylistIdx(Number(e.target.value));
          setSelectedEntryIdx(null); // Clear selection when switching playlists
        }}
        className="flex-1 min-w-[120px] bg-bg-surface border border-border-subtle rounded-lg px-2 py-1.5 text-text-primary text-sm"
      >
        {playlists.map((pl, idx) => (
          <option key={idx} value={idx}>
            {pl.name}
            {isPlaylistActive && activePlaylistIndex === idx ? ' ▶' : ''}
          </option>
        ))}
      </select>

      {/* Reorder mode toggle */}
      <button
        onClick={() => setReorderMode(!reorderMode)}
        className={`p-1.5 rounded-lg transition-colors ${
          reorderMode
            ? 'bg-primary hover:bg-primary-hover text-text-on-primary'
            : 'bg-bg-surface hover:bg-bg-elevated'
        }`}
        title={reorderMode ? 'Exit reorder mode' : 'Reorder entries'}
      >
        <Move size={18} />
      </button>

      {/* CRUD buttons */}
      <button
        onClick={() => setShowCreateModal(true)}
        className="p-1.5 bg-bg-surface hover:bg-bg-elevated rounded-lg transition-colors"
        title="Create playlist"
      >
        <Plus size={18} />
      </button>
      <button
        onClick={() => {
          setNewPlaylistName(currentPlaylist?.name ?? '');
          setShowRenameModal(true);
        }}
        className="p-1.5 bg-bg-surface hover:bg-bg-elevated rounded-lg transition-colors"
        title="Rename playlist"
      >
        <Pencil size={18} />
      </button>
      <button
        onClick={() => setShowDeleteModal(true)}
        className="p-1.5 bg-bg-surface hover:bg-error-action/20 rounded-lg transition-colors"
        title="Delete playlist"
      >
        <Trash2 size={18} />
      </button>
    </ViewHeader>
  );

  return (
    <ViewLayout
      viewId="playlist"
      className="bg-bg-app text-text-primary p-view"
      header={headerContent}
    >
      {/* Entry list - padding at bottom for fixed playback controls */}
      <div style={{ paddingBottom: `${PLAYBACK_CONTROLS_HEIGHT}px` }}>
        {currentPlaylist && currentPlaylist.entries.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-center py-16">
            <p className="text-text-secondary mb-4">This playlist is empty</p>
            <p className="text-text-muted text-sm mb-6">Add regions to build your setlist</p>
            <button
              onClick={() => setShowRegionPicker(true)}
              className="px-4 py-2 bg-primary hover:bg-primary-hover rounded-lg font-medium transition-colors"
            >
              Add Region
            </button>
          </div>
        ) : (
          <div className="space-y-2">
            {currentPlaylist?.entries.map((entry, idx) => {
              const region = getRegionById(regions, entry.regionId);
              const isNowPlaying =
                isPlaylistActive &&
                activePlaylistIndex === selectedPlaylistIdx &&
                currentEntryIndex === idx;

              return (
                <PlaylistEntryRow
                  key={`${entry.regionId}-${idx}`}
                  entry={entry}
                  entryIdx={idx}
                  region={region}
                  isNowPlaying={isNowPlaying}
                  isSelected={selectedEntryIdx === idx}
                  loopsRemaining={isNowPlaying ? loopsRemaining : null}
                  currentLoopIteration={isNowPlaying ? currentLoopIteration : null}
                  reorderMode={reorderMode}
                  onSelect={() => handleSelectEntry(idx)}
                  onSetLoopCount={(count) => handleSetLoopCount(idx, count)}
                  onRemove={() => handleRemoveEntry(idx)}
                  onPlayFrom={() => handlePlayFromEntry(idx)}
                  isDragging={draggedIdx === idx}
                  isDropTarget={dropTargetIdx === idx}
                  onDragStart={() => handleDragStart(idx)}
                  onDragOver={(e) => handleDragOver(e, idx)}
                  onDragEnd={handleDragEnd}
                  onDrop={() => handleDrop(idx)}
                  onTouchStart={(e) => handleTouchStart(e, idx)}
                  onTouchMove={handleTouchMove}
                  onTouchEnd={handleTouchEnd}
                  entryRef={(el) => {
                    if (el) {
                      entryRefs.current.set(idx, el);
                    } else {
                      entryRefs.current.delete(idx);
                    }
                  }}
                />
              );
            })}

            {/* Add region button at bottom of list */}
            <button
              onClick={() => setShowRegionPicker(true)}
              className="w-full py-3 border-2 border-dashed border-border-subtle hover:border-bg-hover rounded-lg text-text-secondary hover:text-text-tertiary transition-colors"
            >
              + Add Region
            </button>
          </div>
        )}
      </div>

      {/* Playback controls - fixed at bottom, above navbar/transport + safe area */}
      <div
        className="fixed left-0 right-0 z-fixed p-3 border-t border-border-muted bg-bg-deep safe-area-x"
        style={{ bottom: `calc(${bottomOffset}px + env(safe-area-inset-bottom, 0px))` }}
      >
        <div className="flex items-center justify-center gap-3">
          <button
            onClick={handlePrev}
            disabled={!isPlaylistActive}
            className="w-12 h-12 flex items-center justify-center bg-bg-surface hover:bg-bg-elevated disabled:bg-bg-deep disabled:text-text-disabled rounded-lg transition-colors"
            title="Previous"
          >
            <SkipBack size={24} />
          </button>

          {isPlaylistActive && !isPaused ? (
            <button
              onClick={handlePause}
              className="w-14 h-14 flex items-center justify-center bg-primary hover:bg-primary-hover rounded-lg transition-colors"
              title="Pause"
            >
              <Pause size={28} />
            </button>
          ) : (
            <button
              onClick={handlePlay}
              disabled={!currentPlaylist || currentPlaylist.entries.length === 0}
              className="w-14 h-14 flex items-center justify-center bg-primary hover:bg-primary-hover disabled:bg-bg-deep disabled:text-text-disabled rounded-lg transition-colors"
              title="Play"
            >
              <Play size={28} />
            </button>
          )}

          <button
            onClick={handleStop}
            disabled={!isPlaylistActive}
            className="w-12 h-12 flex items-center justify-center bg-bg-surface hover:bg-bg-elevated disabled:bg-bg-deep disabled:text-text-disabled rounded-lg transition-colors"
            title="Stop"
          >
            <Square size={24} />
          </button>

          <button
            onClick={handleNext}
            disabled={!isPlaylistActive}
            className="w-12 h-12 flex items-center justify-center bg-bg-surface hover:bg-bg-elevated disabled:bg-bg-deep disabled:text-text-disabled rounded-lg transition-colors"
            title="Next"
          >
            <SkipForward size={24} />
          </button>

          {/* Advance after loop - skip to next region after current loop finishes */}
          <button
            onClick={handleAdvanceAfterLoop}
            disabled={!isPlaylistActive}
            className={`w-12 h-12 flex items-center justify-center rounded-lg transition-colors ${
              advanceAfterLoop
                ? 'bg-warning-bright hover:bg-warning text-text-primary'
                : 'bg-bg-surface hover:bg-bg-elevated disabled:bg-bg-deep disabled:text-text-disabled'
            }`}
            title="Advance to next region after current loop iteration"
          >
            <ArrowRightFromLine size={20} />
          </button>
        </div>
      </div>

      {/* Modals */}
      {showCreateModal && (
        <CreatePlaylistModal
          value={newPlaylistName}
          onChange={setNewPlaylistName}
          onCreate={handleCreatePlaylist}
          onCancel={() => {
            setShowCreateModal(false);
            setNewPlaylistName('');
          }}
        />
      )}

      {showRenameModal && (
        <RenamePlaylistModal
          value={newPlaylistName}
          onChange={setNewPlaylistName}
          onRename={handleRenamePlaylist}
          onCancel={() => {
            setShowRenameModal(false);
            setNewPlaylistName('');
          }}
        />
      )}

      {showDeleteModal && (
        <DeletePlaylistModal
          playlistName={currentPlaylist?.name ?? ''}
          onDelete={handleDeletePlaylist}
          onCancel={() => setShowDeleteModal(false)}
        />
      )}

      {showRegionPicker && (
        <RegionPickerModal
          regions={regions}
          regionIdsInPlaylist={regionIdsInPlaylist}
          onAdd={handleAddRegion}
          onAddAll={handleAddAllRegions}
          onClose={() => setShowRegionPicker(false)}
        />
      )}
    </ViewLayout>
  );
}
