/**
 * CuesView - Playlist management and playback
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
  X,
  Minus,
  Infinity,
  AlertTriangle,
  GripVertical,
  Move,
  ListMusic,
} from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../../components/ReaperProvider';
import { ViewHeader } from '../../components';
import { playlist as playlistCmd } from '../../core/WebSocketCommands';
import type { WSPlaylist, WSPlaylistEntry } from '../../core/WebSocketTypes';
import type { Region } from '../../core/types';
import { reaperColorToHexWithFallback } from '../../utils/color';
import { useTransportAnimation, useUIPreferences } from '../../hooks';

// Fixed heights for bottom bar calculations
const TAB_BAR_HEIGHT = 48;
const PERSISTENT_TRANSPORT_HEIGHT = 56;
const PLAYBACK_CONTROLS_HEIGHT = 80;

// Helper to format duration
function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

// Helper to get region by ID
function getRegionById(regions: Region[], regionId: number): Region | undefined {
  return regions.find((r) => r.id === regionId);
}

// Loop count display
function formatLoopCount(count: number): string {
  if (count === -1) return '∞';
  if (count === 0) return 'Skip';
  return `${count}x`;
}

export function CuesView(): ReactElement {
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
  const listRef = useRef<HTMLDivElement>(null);
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
      <div data-view="cues" className="h-full bg-gray-950 text-white p-3 flex flex-col">
        <ViewHeader currentView="cues" />
        {/* Wrapper - position content at bottom with padding for footer bars */}
        <div
          className="flex-1 overflow-auto flex flex-col justify-end"
          style={{ paddingBottom: `${bottomOffset + 24}px` }}
        >
          {/* Empty state content */}
          <div className="flex flex-col items-center text-center py-8">
            <ListMusic size={48} className="text-gray-600 mb-4" />
            <h2 className="text-xl font-medium text-gray-300 mb-2">No Playlists Yet</h2>
            <p className="text-gray-500 mb-6 max-w-xs">
              Practice, perform, or explore song arrangements from your project regions. Adjust loop counts per region on the fly.
            </p>
            <button
              onClick={() => setShowCreateModal(true)}
              className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-500 transition-colors"
            >
              <Plus size={18} />
              <span>Create Playlist</span>
            </button>
          </div>
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
      </div>
    );
  }

  return (
    <div data-view="cues" className="h-full bg-gray-950 text-white p-3 flex flex-col">
      {/* Header */}
      <ViewHeader currentView="cues">
        {/* Playlist selector */}
        <select
          value={selectedPlaylistIdx}
          onChange={(e) => {
            setSelectedPlaylistIdx(Number(e.target.value));
            setSelectedEntryIdx(null); // Clear selection when switching playlists
          }}
          className="flex-1 min-w-[120px] bg-gray-800 border border-gray-700 rounded-lg px-2 py-1.5 text-white text-sm"
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
              ? 'bg-blue-600 hover:bg-blue-500 text-white'
              : 'bg-gray-800 hover:bg-gray-700'
          }`}
          title={reorderMode ? 'Exit reorder mode' : 'Reorder entries'}
        >
          <Move size={18} />
        </button>

        {/* CRUD buttons */}
        <button
          onClick={() => setShowCreateModal(true)}
          className="p-1.5 bg-gray-800 hover:bg-gray-700 rounded-lg transition-colors"
          title="Create playlist"
        >
          <Plus size={18} />
        </button>
        <button
          onClick={() => {
            setNewPlaylistName(currentPlaylist?.name ?? '');
            setShowRenameModal(true);
          }}
          className="p-1.5 bg-gray-800 hover:bg-gray-700 rounded-lg transition-colors"
          title="Rename playlist"
        >
          <Pencil size={18} />
        </button>
        <button
          onClick={() => setShowDeleteModal(true)}
          className="p-1.5 bg-gray-800 hover:bg-red-900 rounded-lg transition-colors"
          title="Delete playlist"
        >
          <Trash2 size={18} />
        </button>
      </ViewHeader>

      {/* Entry list - add padding for fixed playback controls */}
      <div
        ref={listRef}
        className="flex-1 overflow-auto"
        style={{ paddingBottom: `${PLAYBACK_CONTROLS_HEIGHT}px` }}
      >
        {currentPlaylist && currentPlaylist.entries.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-center">
            <p className="text-gray-400 mb-4">This playlist is empty</p>
            <p className="text-gray-500 text-sm mb-6">Add regions to build your setlist</p>
            <button
              onClick={() => setShowRegionPicker(true)}
              className="px-4 py-2 bg-blue-600 hover:bg-blue-500 rounded-lg font-medium transition-colors"
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
              className="w-full py-3 border-2 border-dashed border-gray-700 hover:border-gray-500 rounded-lg text-gray-400 hover:text-gray-300 transition-colors"
            >
              + Add Region
            </button>
          </div>
        )}
      </div>

      {/* Playback controls - fixed at bottom, above navbar/transport + safe area */}
      <div
        className="fixed left-0 right-0 z-40 p-3 border-t border-gray-800 bg-gray-900 safe-area-x"
        style={{ bottom: `calc(${bottomOffset}px + env(safe-area-inset-bottom, 0px))` }}
      >
        <div className="flex items-center justify-center gap-3">
          <button
            onClick={handlePrev}
            disabled={!isPlaylistActive}
            className="w-12 h-12 flex items-center justify-center bg-gray-800 hover:bg-gray-700 disabled:bg-gray-900 disabled:text-gray-600 rounded-lg transition-colors"
            title="Previous"
          >
            <SkipBack size={24} />
          </button>

          {isPlaylistActive && !isPaused ? (
            <button
              onClick={handlePause}
              className="w-14 h-14 flex items-center justify-center bg-blue-600 hover:bg-blue-500 rounded-lg transition-colors"
              title="Pause"
            >
              <Pause size={28} />
            </button>
          ) : (
            <button
              onClick={handlePlay}
              disabled={!currentPlaylist || currentPlaylist.entries.length === 0}
              className="w-14 h-14 flex items-center justify-center bg-blue-600 hover:bg-blue-500 disabled:bg-gray-900 disabled:text-gray-600 rounded-lg transition-colors"
              title="Play"
            >
              <Play size={28} />
            </button>
          )}

          <button
            onClick={handleStop}
            disabled={!isPlaylistActive}
            className="w-12 h-12 flex items-center justify-center bg-gray-800 hover:bg-gray-700 disabled:bg-gray-900 disabled:text-gray-600 rounded-lg transition-colors"
            title="Stop"
          >
            <Square size={24} />
          </button>

          <button
            onClick={handleNext}
            disabled={!isPlaylistActive}
            className="w-12 h-12 flex items-center justify-center bg-gray-800 hover:bg-gray-700 disabled:bg-gray-900 disabled:text-gray-600 rounded-lg transition-colors"
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
                ? 'bg-orange-600 hover:bg-orange-500 text-white'
                : 'bg-gray-800 hover:bg-gray-700 disabled:bg-gray-900 disabled:text-gray-600'
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
    </div>
  );
}

// =============================================================================
// Sub-components
// =============================================================================

interface PlaylistEntryRowProps {
  entry: WSPlaylistEntry;
  entryIdx: number;
  region: Region | undefined;
  isNowPlaying: boolean;
  isSelected: boolean;
  loopsRemaining: number | null;
  currentLoopIteration: number | null;
  reorderMode: boolean;
  onSelect: () => void;
  onSetLoopCount: (count: number) => void;
  onRemove: () => void;
  onPlayFrom: () => void;
  isDragging: boolean;
  isDropTarget: boolean;
  onDragStart: () => void;
  onDragOver: (e: React.DragEvent) => void;
  onDragEnd: () => void;
  onDrop: () => void;
  onTouchStart: (e: React.TouchEvent) => void;
  onTouchMove: (e: React.TouchEvent) => void;
  onTouchEnd: () => void;
  entryRef: (el: HTMLDivElement | null) => void;
}

function PlaylistEntryRow({
  entry,
  region,
  isNowPlaying,
  isSelected,
  loopsRemaining,
  currentLoopIteration,
  reorderMode,
  onSelect,
  onSetLoopCount,
  onRemove,
  onPlayFrom,
  isDragging,
  isDropTarget,
  onDragStart,
  onDragOver,
  onDragEnd,
  onDrop,
  onTouchStart,
  onTouchMove,
  onTouchEnd,
  entryRef,
}: PlaylistEntryRowProps): ReactElement {
  const regionColor = region?.color ? reaperColorToHexWithFallback(region.color, '#6b7280') : '#6b7280';
  const regionName = region?.name ?? `Region ${entry.regionId}`;
  const duration = region ? formatDuration(region.end - region.start) : '--:--';

  // Ref for progress bar direct DOM updates at 60fps
  const progressBarRef = useRef<HTMLDivElement>(null);

  // Use the animation hook for 60fps progress bar updates when playing
  useTransportAnimation(
    useCallback((state) => {
      if (!isNowPlaying || !region || !progressBarRef.current) return;
      const regionDuration = region.end - region.start;
      if (regionDuration > 0) {
        const posInRegion = state.position - region.start;
        const percent = Math.max(0, Math.min(100, (posInRegion / regionDuration) * 100));
        progressBarRef.current.style.width = `${percent}%`;
      }
    }, [isNowPlaying, region]),
    [isNowPlaying, region]
  );

  // Loop progress display
  let loopProgress = '';
  if (isNowPlaying && currentLoopIteration !== null) {
    if (entry.loopCount === -1) {
      loopProgress = `Loop ${currentLoopIteration}`;
    } else if (entry.loopCount > 1 && loopsRemaining !== null) {
      // Show "Loop X / Y" using iteration count
      loopProgress = `Loop ${currentLoopIteration} / ${entry.loopCount}`;
    }
  }

  // Handle click - select in normal mode, ignore in reorder mode
  const handleClick = () => {
    if (!reorderMode) {
      onSelect();
    }
  };

  return (
    <div
      ref={entryRef}
      draggable={reorderMode}
      onDragStart={reorderMode ? onDragStart : undefined}
      onDragOver={reorderMode ? onDragOver : undefined}
      onDragEnd={reorderMode ? onDragEnd : undefined}
      onDrop={reorderMode ? onDrop : undefined}
      onTouchStart={reorderMode ? onTouchStart : undefined}
      onTouchMove={reorderMode ? onTouchMove : undefined}
      onTouchEnd={reorderMode ? onTouchEnd : undefined}
      className={`relative overflow-hidden transition-colors ${
        reorderMode ? 'touch-none select-none cursor-grab' : 'cursor-pointer'
      } ${
        isNowPlaying
          ? 'bg-gray-800 rounded-lg'
          : isSelected
            ? 'bg-gray-800 rounded-lg border-l-4 border-l-blue-500'
            : 'bg-gray-800 hover:bg-gray-750 rounded-lg'
      } ${entry.deleted ? 'opacity-50' : ''} ${
        isDragging ? 'opacity-50 cursor-grabbing' : ''
      } ${isDropTarget ? 'ring-2 ring-blue-400' : ''}`}
      style={isNowPlaying ? { borderLeft: `4px solid ${regionColor}`, borderRadius: '0.5rem' } : undefined}
      onClick={handleClick}
      onDoubleClick={onPlayFrom}
    >
      {/* Progress bar at top */}
      <div
        className="absolute top-0 left-0 right-0 h-1"
        style={{ backgroundColor: `${regionColor}40` }}
      >
        {isNowPlaying && (
          <div
            ref={progressBarRef}
            className="h-full"
            style={{
              width: '0%',
              backgroundColor: regionColor,
            }}
          />
        )}
      </div>

      {/* Content row */}
      <div className="flex items-center gap-2 p-3 pt-4">
        {/* Drag handle - only in reorder mode */}
        {reorderMode && (
          <div className="flex-none cursor-grab active:cursor-grabbing text-gray-500 hover:text-gray-300">
            <GripVertical size={20} />
          </div>
        )}

        {/* Region info */}
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium truncate">{regionName}</span>
            {entry.deleted && (
              <span className="text-orange-400 text-xs flex items-center gap-1">
                <AlertTriangle size={12} /> Deleted
              </span>
            )}
          </div>
          <div className="text-sm text-gray-400 flex items-center gap-2">
            <span>{duration}</span>
            {loopProgress && (
              <span className="text-blue-400">• {loopProgress}</span>
            )}
          </div>
        </div>

        {/* Loop count stepper */}
        <div className="flex items-center gap-1">
          <button
            onClick={() => {
              if (entry.loopCount > 0) {
                onSetLoopCount(entry.loopCount - 1);
              }
            }}
            disabled={entry.loopCount === -1}
            className="w-8 h-8 flex items-center justify-center bg-gray-700 hover:bg-gray-600 disabled:bg-gray-800 disabled:text-gray-600 rounded transition-colors"
          >
            <Minus size={16} />
          </button>
          <span className="w-10 text-center font-mono">
            {formatLoopCount(entry.loopCount)}
          </span>
          <button
            onClick={() => {
              if (entry.loopCount >= 0) {
                onSetLoopCount(entry.loopCount + 1);
              }
            }}
            disabled={entry.loopCount === -1}
            className="w-8 h-8 flex items-center justify-center bg-gray-700 hover:bg-gray-600 disabled:bg-gray-800 disabled:text-gray-600 rounded transition-colors"
          >
            <Plus size={16} />
          </button>
          <button
            onClick={() => onSetLoopCount(entry.loopCount === -1 ? 1 : -1)}
            className={`w-8 h-8 flex items-center justify-center rounded transition-colors ${
              entry.loopCount === -1
                ? 'bg-purple-600 hover:bg-purple-500 text-white'
                : 'bg-gray-700 hover:bg-gray-600'
            }`}
            title="Infinite loops"
          >
            <Infinity size={16} />
          </button>
        </div>

        {/* Remove button */}
        <button
          onClick={onRemove}
          className="w-8 h-8 flex items-center justify-center text-gray-500 hover:text-red-400 transition-colors"
          title="Remove from playlist"
        >
          <X size={18} />
        </button>
      </div>
    </div>
  );
}

// =============================================================================
// Modal components
// =============================================================================

interface CreatePlaylistModalProps {
  value: string;
  onChange: (value: string) => void;
  onCreate: () => void;
  onCancel: () => void;
}

function CreatePlaylistModal({ value, onChange, onCreate, onCancel }: CreatePlaylistModalProps): ReactElement {
  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onCancel}>
      <div className="bg-gray-800 rounded-lg p-4 w-full max-w-sm" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-semibold mb-4">Create Playlist</h3>
        <input
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="Playlist name"
          className="w-full bg-gray-900 border border-gray-700 rounded-lg px-3 py-2 text-white mb-4 focus:outline-none focus:ring-2 focus:ring-blue-500"
          autoFocus
          onKeyDown={(e) => {
            if (e.key === 'Enter') onCreate();
            if (e.key === 'Escape') onCancel();
          }}
        />
        <div className="flex gap-2">
          <button
            onClick={onCancel}
            className="flex-1 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={onCreate}
            disabled={!value.trim()}
            className="flex-1 py-2 bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700 disabled:text-gray-500 rounded-lg transition-colors"
          >
            Create
          </button>
        </div>
      </div>
    </div>
  );
}

interface RenamePlaylistModalProps {
  value: string;
  onChange: (value: string) => void;
  onRename: () => void;
  onCancel: () => void;
}

function RenamePlaylistModal({ value, onChange, onRename, onCancel }: RenamePlaylistModalProps): ReactElement {
  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onCancel}>
      <div className="bg-gray-800 rounded-lg p-4 w-full max-w-sm" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-semibold mb-4">Rename Playlist</h3>
        <input
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="Playlist name"
          className="w-full bg-gray-900 border border-gray-700 rounded-lg px-3 py-2 text-white mb-4 focus:outline-none focus:ring-2 focus:ring-blue-500"
          autoFocus
          onKeyDown={(e) => {
            if (e.key === 'Enter') onRename();
            if (e.key === 'Escape') onCancel();
          }}
        />
        <div className="flex gap-2">
          <button
            onClick={onCancel}
            className="flex-1 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={onRename}
            disabled={!value.trim()}
            className="flex-1 py-2 bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700 disabled:text-gray-500 rounded-lg transition-colors"
          >
            Rename
          </button>
        </div>
      </div>
    </div>
  );
}

interface DeletePlaylistModalProps {
  playlistName: string;
  onDelete: () => void;
  onCancel: () => void;
}

function DeletePlaylistModal({ playlistName, onDelete, onCancel }: DeletePlaylistModalProps): ReactElement {
  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4" onClick={onCancel}>
      <div className="bg-gray-800 rounded-lg p-4 w-full max-w-sm" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-semibold mb-2">Delete Playlist?</h3>
        <p className="text-gray-400 mb-4">
          Are you sure you want to delete "{playlistName}"? This cannot be undone.
        </p>
        <div className="flex gap-2">
          <button
            onClick={onCancel}
            className="flex-1 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={onDelete}
            className="flex-1 py-2 bg-red-600 hover:bg-red-500 rounded-lg transition-colors"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
  );
}

interface RegionPickerModalProps {
  regions: Region[];
  regionIdsInPlaylist: Set<number>;
  onAdd: (regionId: number) => void;
  onAddAll: () => void;
  onClose: () => void;
}

function RegionPickerModal({
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
        <div className="bg-gray-800 rounded-lg p-4 w-full max-w-md" onClick={(e) => e.stopPropagation()}>
          <h3 className="text-lg font-semibold mb-4">Add Region</h3>
          <p className="text-gray-400 mb-4 text-center">
            No regions in this project. Create regions in REAPER to add them here.
          </p>
          <button
            onClick={onClose}
            className="w-full py-2 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
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
        className="bg-gray-800 rounded-lg w-full max-w-md max-h-[80vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="p-4 border-b border-gray-700">
          <h3 className="text-lg font-semibold">Add Region</h3>
        </div>

        {/* Add All button */}
        <div className="p-3 border-b border-gray-700">
          <button
            onClick={onAddAll}
            className="w-full py-2 bg-blue-600 hover:bg-blue-500 rounded-lg font-medium transition-colors"
          >
            Add All Regions ({regions.length})
          </button>
        </div>

        {/* Region list */}
        <div className="flex-1 overflow-auto p-3">
          <div className="space-y-2">
            {sortedRegions.map((region) => {
              const inPlaylist = regionIdsInPlaylist.has(region.id);
              const color = reaperColorToHexWithFallback(region.color, '#6b7280');

              return (
                <button
                  key={region.id}
                  onClick={() => {
                    onAdd(region.id);
                  }}
                  className="w-full flex items-center gap-3 p-3 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors text-left"
                >
                  <div
                    className="w-1.5 h-8 rounded-full flex-none"
                    style={{ backgroundColor: color }}
                  />
                  <div className="flex-1 min-w-0">
                    <div className="font-medium truncate">{region.name}</div>
                    <div className="text-sm text-gray-400">
                      {formatDuration(region.end - region.start)}
                    </div>
                  </div>
                  {inPlaylist && (
                    <span className="text-gray-500 text-sm">In list</span>
                  )}
                </button>
              );
            })}
          </div>
        </div>

        <div className="p-3 border-t border-gray-700">
          <button
            onClick={onClose}
            className="w-full py-2 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
