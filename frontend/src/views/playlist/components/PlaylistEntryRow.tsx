/**
 * PlaylistEntryRow - Individual playlist entry with progress bar and drag-drop support
 */

import { useRef, useCallback, type ReactElement } from 'react';
import {
  Minus,
  Plus,
  Infinity as InfinityIcon,
  AlertTriangle,
  GripVertical,
  X,
} from 'lucide-react';
import type { WSPlaylistEntry } from '../../../core/WebSocketTypes';
import type { Region } from '../../../core/types';
import { reaperColorToHexWithFallback } from '../../../utils/color';
import { useTransportAnimation } from '../../../hooks';

// Helper to format duration
function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

// Loop count display
function formatLoopCount(count: number): string {
  if (count === -1) return '∞';
  if (count === 0) return 'Skip';
  return `${count}x`;
}

export interface PlaylistEntryRowProps {
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

export function PlaylistEntryRow({
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
  const regionColor = region?.color ? reaperColorToHexWithFallback(region.color, 'var(--color-text-muted)') : 'var(--color-text-muted)';
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
        reorderMode ? 'touch-none cursor-grab' : 'cursor-pointer'
      } ${
        isNowPlaying
          ? 'bg-bg-surface rounded-lg'
          : isSelected
            ? 'bg-bg-surface rounded-lg border-l-4 border-l-row-selected-border'
            : 'bg-bg-surface hover:bg-bg-elevated rounded-lg'
      } ${entry.deleted ? 'opacity-50' : ''} ${
        isDragging ? 'opacity-50 cursor-grabbing' : ''
      } ${isDropTarget ? 'ring-2 ring-control-ring' : ''}`}
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
          <div className="flex-none cursor-grab active:cursor-grabbing text-text-muted hover:text-text-tertiary">
            <GripVertical size={20} />
          </div>
        )}

        {/* Region info */}
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium truncate">{regionName}</span>
            {entry.deleted && (
              <span className="text-external-text text-xs flex items-center gap-1">
                <AlertTriangle size={12} /> Deleted
              </span>
            )}
          </div>
          <div className="text-sm text-text-secondary flex items-center gap-2">
            <span>{duration}</span>
            {loopProgress && (
              <span className="text-info">• {loopProgress}</span>
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
            className="w-8 h-8 flex items-center justify-center bg-bg-elevated hover:bg-bg-hover disabled:bg-bg-surface disabled:text-text-disabled rounded transition-colors"
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
            className="w-8 h-8 flex items-center justify-center bg-bg-elevated hover:bg-bg-hover disabled:bg-bg-surface disabled:text-text-disabled rounded transition-colors"
          >
            <Plus size={16} />
          </button>
          <button
            onClick={() => onSetLoopCount(entry.loopCount === -1 ? 1 : -1)}
            className={`w-8 h-8 flex items-center justify-center rounded transition-colors ${
              entry.loopCount === -1
                ? 'bg-accent-region hover:bg-accent-region-hover text-text-on-accent'
                : 'bg-bg-elevated hover:bg-bg-hover'
            }`}
            title="Infinite loops"
          >
            <InfinityIcon size={16} />
          </button>
        </div>

        {/* Remove button */}
        <button
          onClick={onRemove}
          className="w-8 h-8 flex items-center justify-center text-text-muted hover:text-error-text transition-colors"
          title="Remove from playlist"
        >
          <X size={18} />
        </button>
      </div>
    </div>
  );
}
