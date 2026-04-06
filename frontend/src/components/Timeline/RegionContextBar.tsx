/**
 * Region Context Bar
 * Compact persistent bar showing selected region info + quick actions.
 * All operations go directly to REAPER via WebSocket.
 *
 * Layout when region selected:
 *   [color] Name  |  Start → End  |  Length  [Set Sel] [Del] [+]
 *
 * Layout when no region selected:
 *   "Select a region to edit"  [+]
 *
 * Layout when no regions exist:
 *   "Add a region"  [+]
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { Plus, Trash2, CopyPlus, Crosshair } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTimeFormatters } from '../../hooks';
import { reaperColorToHexWithFallback } from '../../utils';
import type { Region } from '../../core/types';
import { DEFAULT_REGION_COLOR } from '../../constants/colors';
import { region as regionCmd, timeSelection } from '../../core/WebSocketCommands';

interface RegionContextBarProps {
  onAddRegion: () => void;
  /** Vertical layout for landscape sidebar */
  layout?: 'horizontal' | 'vertical';
  className?: string;
}

export function RegionContextBar({ onAddRegion, layout = 'horizontal', className = '' }: RegionContextBarProps): ReactElement {
  const { sendCommand } = useReaper();
  const selectedRegionIds = useReaperStore((s) => s.selectedRegionIds);
  const regions = useReaperStore((s) => s.regions);

  const {
    formatBeats,
    formatDuration,
  } = useTimeFormatters();

  // Delete confirmation (tap once = red, tap again = delete)
  const [confirmDelete, setConfirmDelete] = useState(false);
  const deleteTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Long-press for clone
  const longPressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isLongPressRef = useRef(false);
  const addButtonRef = useRef<HTMLButtonElement>(null);
  const [isCloneMode, setIsCloneMode] = useState(false);
  const LONG_PRESS_DURATION = 500;

  // Reset delete confirmation when selection changes
  useEffect(() => {
    setConfirmDelete(false);
    if (deleteTimeoutRef.current) { clearTimeout(deleteTimeoutRef.current); deleteTimeoutRef.current = null; }
  }, [selectedRegionIds]);

  useEffect(() => {
    return () => {
      if (longPressTimerRef.current) clearTimeout(longPressTimerRef.current);
      if (deleteTimeoutRef.current) clearTimeout(deleteTimeoutRef.current);
    };
  }, []);

  const selectedId = selectedRegionIds.length === 1 ? selectedRegionIds[0] : null;
  const region: Region | undefined = selectedId !== null
    ? regions.find(r => r.id === selectedId)
    : undefined;

  // Bar strings directly from server-provided region data
  const displayStartBars = region?.startBars ?? (region ? formatBeats(region.start) : '');
  const displayEndBars = region?.endBars ?? (region ? formatBeats(region.end) : '');
  const displayLengthBars = region?.lengthBars ?? (region ? formatDuration(region.end - region.start) : '');

  const currentColor = region ? reaperColorToHexWithFallback(region.color, DEFAULT_REGION_COLOR) : DEFAULT_REGION_COLOR;

  // Set time selection to region bounds
  const handleSetTimeSelection = () => {
    if (!region) return;
    sendCommand(timeSelection.set(region.start, region.end));
  };

  // Delete (tap once = confirm, tap again = delete)
  const handleDelete = () => {
    if (!region) return;
    if (!confirmDelete) {
      setConfirmDelete(true);
      deleteTimeoutRef.current = setTimeout(() => setConfirmDelete(false), 3000);
    } else {
      sendCommand(regionCmd.delete(region.id));
      setConfirmDelete(false);
      if (deleteTimeoutRef.current) { clearTimeout(deleteTimeoutRef.current); deleteTimeoutRef.current = null; }
    }
  };

  // Clone selected region
  const handleCloneRegion = () => {
    if (!region) return;
    const lastEnd = regions.length > 0 ? Math.max(...regions.map(r => r.end)) : 0;
    const duration = region.end - region.start;
    sendCommand(regionCmd.add(lastEnd, lastEnd + duration, region.name, region.color));
  };

  // Add button long-press handlers
  const handleAddPointerDown = () => {
    isLongPressRef.current = false;
    setIsCloneMode(false);
    if (region) {
      longPressTimerRef.current = setTimeout(() => {
        isLongPressRef.current = true;
        setIsCloneMode(true);
      }, LONG_PRESS_DURATION);
    }
  };

  const handleAddPointerUp = () => {
    if (longPressTimerRef.current) { clearTimeout(longPressTimerRef.current); longPressTimerRef.current = null; }
    if (isLongPressRef.current && region) {
      handleCloneRegion();
    } else if (!isLongPressRef.current) {
      onAddRegion();
    }
    setIsCloneMode(false);
  };

  const handleAddPointerLeave = () => {
    if (longPressTimerRef.current) { clearTimeout(longPressTimerRef.current); longPressTimerRef.current = null; }
    isLongPressRef.current = false;
    setIsCloneMode(false);
  };

  // Button styles
  const actionBtn = 'flex items-center justify-center w-9 h-9 rounded-lg transition-colors flex-shrink-0';

  // No regions at all
  if (regions.length === 0) {
    return (
      <div className={`flex items-center gap-2 px-3 py-2 ${className}`}>
        <span className="text-text-muted text-sm flex-1">Add a region</span>
        <button
          onClick={onAddRegion}
          className={`${actionBtn} bg-accent-region hover:bg-accent-region-hover text-text-primary`}
          title="Add new region"
        >
          <Plus size={18} />
        </button>
      </div>
    );
  }

  // No region selected
  if (!region) {
    return (
      <div className={`flex items-center gap-2 px-3 py-2 ${className}`}>
        <span className="text-text-muted text-sm flex-1">Select a region to edit</span>
        <button
          onClick={onAddRegion}
          className={`${actionBtn} bg-accent-region hover:bg-accent-region-hover text-text-primary`}
          title="Add new region"
        >
          <Plus size={18} />
        </button>
      </div>
    );
  }

  // Strip trailing .00 from bar strings for compact display
  const startDisplay = displayStartBars.replace(/\.00$/, '');
  const endDisplay = displayEndBars.replace(/\.00$/, '');
  const lengthDisplay = displayLengthBars.replace(/\.00$/, '');

  if (layout === 'vertical') {
    return (
      <div className={`flex flex-col gap-2 px-3 py-2 ${className}`}>
        {/* Name + color */}
        <div className="flex items-center gap-2">
          <div
            className="w-3 h-3 rounded-sm flex-shrink-0 border border-border-default"
            style={{ backgroundColor: currentColor }}
          />
          <span className="text-sm font-medium text-text-primary truncate">{region.name}</span>
        </div>

        {/* Position info */}
        <div className="flex flex-col gap-1 text-xs font-mono text-text-secondary">
          <span>{startDisplay} → {endDisplay}</span>
          <span className="text-accent-region-hover">{lengthDisplay}</span>
        </div>

        {/* Actions */}
        <div className="flex items-center gap-1.5">
          <button
            onClick={handleSetTimeSelection}
            className={`${actionBtn} bg-bg-elevated hover:bg-bg-hover text-text-secondary`}
            title="Set time selection to region"
          >
            <Crosshair size={16} />
          </button>
          <button
            onClick={handleDelete}
            className={`${actionBtn} ${
              confirmDelete
                ? 'bg-error-bg text-error-text'
                : 'bg-bg-elevated hover:bg-error-bg text-text-secondary hover:text-error-text'
            }`}
            title={confirmDelete ? 'Tap again to confirm delete' : 'Delete region'}
          >
            <Trash2 size={16} />
          </button>
          <button
            ref={addButtonRef}
            onPointerDown={handleAddPointerDown}
            onPointerUp={handleAddPointerUp}
            onPointerLeave={handleAddPointerLeave}
            onPointerCancel={handleAddPointerLeave}
            className={`${actionBtn} touch-none ${
              isCloneMode
                ? 'bg-success-action hover:bg-success text-text-on-success'
                : 'bg-accent-region hover:bg-accent-region-hover text-text-primary'
            }`}
            title={region ? 'Tap to add, hold to clone' : 'Add region'}
          >
            {isCloneMode ? <CopyPlus size={16} /> : <Plus size={16} />}
          </button>
        </div>
      </div>
    );
  }

  // Horizontal layout (portrait)
  return (
    <div className={`flex items-center gap-2 px-3 py-2 ${className}`}>
      {/* Color dot + Name */}
      <div className="flex items-center gap-2 min-w-0 shrink">
        <div
          className="w-3 h-3 rounded-sm flex-shrink-0 border border-border-default"
          style={{ backgroundColor: currentColor }}
        />
        <span className="text-sm font-medium text-text-primary truncate max-w-24">{region.name}</span>
      </div>

      <div className="w-px h-5 bg-border-default flex-shrink-0" />

      {/* Position: Start → End */}
      <div className="flex items-center gap-1 text-xs font-mono text-text-secondary flex-shrink-0">
        <span>{startDisplay}</span>
        <span className="text-text-muted">→</span>
        <span>{endDisplay}</span>
      </div>

      <div className="w-px h-5 bg-border-default flex-shrink-0 hidden sm:block" />

      {/* Length - hidden on very small screens */}
      <span className="text-xs font-mono text-accent-region-hover flex-shrink-0 hidden sm:block">
        {lengthDisplay}
      </span>

      {/* Spacer */}
      <div className="flex-1" />

      {/* Actions */}
      <div className="flex items-center gap-1.5 flex-shrink-0">
        {/* Set time selection */}
        <button
          onClick={handleSetTimeSelection}
          className={`${actionBtn} bg-bg-elevated hover:bg-bg-hover text-text-secondary`}
          title="Set time selection to region"
        >
          <Crosshair size={16} />
        </button>

        {/* Delete */}
        <button
          onClick={handleDelete}
          className={`${actionBtn} ${
            confirmDelete
              ? 'bg-error-bg text-error-text'
              : 'bg-bg-elevated hover:bg-error-bg text-text-secondary hover:text-error-text'
          }`}
          title={confirmDelete ? 'Tap again to confirm delete' : 'Delete region'}
        >
          <Trash2 size={16} />
        </button>

        {/* Add / Clone */}
        <button
          ref={addButtonRef}
          onPointerDown={handleAddPointerDown}
          onPointerUp={handleAddPointerUp}
          onPointerLeave={handleAddPointerLeave}
          onPointerCancel={handleAddPointerLeave}
          className={`${actionBtn} touch-none ${
            isCloneMode
              ? 'bg-success-action hover:bg-success text-text-on-success'
              : 'bg-accent-region hover:bg-accent-region-hover text-text-primary'
          }`}
          title={region ? 'Tap to add, hold to clone' : 'Add region'}
        >
          {isCloneMode ? <CopyPlus size={16} /> : <Plus size={16} />}
        </button>
      </div>
    </div>
  );
}
