/**
 * Region Context Bar
 * Compact persistent bar showing selected region info + quick actions.
 * Lives between the timeline canvas and the SecondaryPanel in portrait,
 * and in the sidebar info section in landscape.
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

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { Plus, Trash2, CopyPlus, Crosshair } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTimeFormatters } from '../../hooks';
import { reaperColorToHexWithFallback } from '../../utils';
import type { Region } from '../../core/types';
import { DEFAULT_REGION_COLOR } from '../../constants/colors';
import { tempo as tempoCmd, timeSelection } from '../../core/WebSocketCommands';

interface RegionContextBarProps {
  onAddRegion: () => void;
  /** Vertical layout for landscape sidebar */
  layout?: 'horizontal' | 'vertical';
  className?: string;
}

/**
 * Parse a bar.beat.ticks string into components
 */
function parseBarsString(bars: string): { bar: number; beat: number; ticks: number } | null {
  const parts = bars.split('.');
  if (parts.length < 2) return null;
  const bar = parseInt(parts[0], 10);
  const beat = parseInt(parts[1], 10);
  const ticks = parts.length >= 3 ? parseInt(parts[2], 10) : 0;
  if (isNaN(bar) || isNaN(beat) || isNaN(ticks)) return null;
  return { bar, beat, ticks };
}

export function RegionContextBar({ onAddRegion, layout = 'horizontal', className = '' }: RegionContextBarProps): ReactElement {
  const { sendCommand, sendCommandAsync } = useReaper();
  const selectedRegionIds = useReaperStore((s) => s.selectedRegionIds);
  const regions = useReaperStore((s) => s.regions);
  const pendingChanges = useReaperStore((s) => s.pendingChanges);
  const getDisplayRegions = useReaperStore((s) => s.getDisplayRegions);
  const createRegion = useReaperStore((s) => s.createRegion);
  const selectRegion = useReaperStore((s) => s.selectRegion);
  const nextNewRegionKey = useReaperStore((s) => s.nextNewRegionKey);
  const openDeleteRegionModal = useReaperStore((s) => s.openDeleteRegionModal);

  const {
    formatBeats,
    formatDuration,
    bpm,
    beatsPerBar,
  } = useTimeFormatters();

  // Pending bar string cache
  const [pendingBarStrings, setPendingBarStrings] = useState<Record<string, { startBars: string; endBars: string; lengthBars: string }>>({});

  // Long-press for clone
  const longPressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const selectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isLongPressRef = useRef(false);
  const addButtonRef = useRef<HTMLButtonElement>(null);
  const [isCloneMode, setIsCloneMode] = useState(false);
  const LONG_PRESS_DURATION = 500;

  useEffect(() => {
    return () => {
      if (longPressTimerRef.current) clearTimeout(longPressTimerRef.current);
      if (selectTimerRef.current) clearTimeout(selectTimerRef.current);
    };
  }, []);

  // Fetch bar strings for pending regions
  useEffect(() => {
    const pendingIds = Object.keys(pendingChanges).map(k => parseInt(k, 10));
    if (pendingIds.length === 0) {
      if (Object.keys(pendingBarStrings).length > 0) setPendingBarStrings({});
      return;
    }

    pendingIds.forEach(async (id) => {
      const change = pendingChanges[id];
      if (!change || change.isDeleted) return;

      const cacheKey = `${id}:${change.newStart}:${change.newEnd}`;
      if (pendingBarStrings[cacheKey]) return;

      try {
        const [startResp, endResp] = await Promise.all([
          sendCommandAsync(tempoCmd.timeToBeats(change.newStart)),
          sendCommandAsync(tempoCmd.timeToBeats(change.newEnd)),
        ]);

        const startData = startResp as { payload?: { bars?: string } } | undefined;
        const endData = endResp as { payload?: { bars?: string } } | undefined;

        if (startData?.payload?.bars && endData?.payload?.bars) {
          const startBars = startData.payload.bars;
          const endBars = endData.payload.bars;
          const startParsed = parseBarsString(startBars);
          const endParsed = parseBarsString(endBars);

          let lengthBars = '';
          if (startParsed && endParsed) {
            let barDiff = endParsed.bar - startParsed.bar;
            let beatDiff = endParsed.beat - startParsed.beat;
            let ticksDiff = endParsed.ticks - startParsed.ticks;
            if (ticksDiff < 0) { beatDiff -= 1; ticksDiff += 100; }
            if (beatDiff < 0) { barDiff -= 1; beatDiff += beatsPerBar; }
            lengthBars = `${barDiff}.${beatDiff}.${ticksDiff.toString().padStart(2, '0')}`;
          }

          setPendingBarStrings(prev => ({
            ...prev,
            [cacheKey]: { startBars, endBars, lengthBars },
          }));
        }
      } catch {
        // Ignore
      }
    });
  }, [pendingChanges, pendingBarStrings, sendCommandAsync, beatsPerBar]);

  const displayRegions = getDisplayRegions(regions);
  const selectedId = selectedRegionIds.length === 1 ? selectedRegionIds[0] : null;
  const region: Region | undefined = selectedId !== null
    ? displayRegions.find(r => r.id === selectedId)
    : undefined;

  // Bar strings
  const pendingChange = selectedId !== null ? pendingChanges[selectedId] : null;
  const hasPending = pendingChange !== null && pendingChange !== undefined;
  const pendingCacheKey = hasPending && region ? `${selectedId}:${region.start}:${region.end}` : null;
  const fetchedBars = pendingCacheKey ? pendingBarStrings[pendingCacheKey] : null;

  const displayStartBars = fetchedBars?.startBars ?? region?.startBars ?? (region ? formatBeats(region.start) : '');
  const displayEndBars = fetchedBars?.endBars ?? region?.endBars ?? (region ? formatBeats(region.end) : '');
  const displayLengthBars = fetchedBars?.lengthBars ?? region?.lengthBars ?? (region ? formatDuration(region.end - region.start) : '');

  const currentColor = region ? reaperColorToHexWithFallback(region.color, DEFAULT_REGION_COLOR) : DEFAULT_REGION_COLOR;

  // Set time selection to region bounds
  const handleSetTimeSelection = useCallback(() => {
    if (!region) return;
    sendCommand(timeSelection.set(region.start, region.end));
  }, [region, sendCommand]);

  // Clone selected region
  const handleCloneRegion = useCallback(() => {
    if (!region || !bpm) return;
    const lastEnd = displayRegions.length > 0
      ? Math.max(...displayRegions.map(r => r.end))
      : 0;
    const duration = region.end - region.start;
    const newRegionKey = nextNewRegionKey;
    createRegion(lastEnd, lastEnd + duration, region.name, bpm, region.color, regions);
    selectTimerRef.current = setTimeout(() => selectRegion(newRegionKey), 0);
  }, [region, bpm, displayRegions, nextNewRegionKey, createRegion, regions, selectRegion]);

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
  if (displayRegions.length === 0) {
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
            onClick={() => openDeleteRegionModal(region, region.id)}
            className={`${actionBtn} bg-bg-elevated hover:bg-error-bg text-text-secondary hover:text-error-text`}
            title="Delete region"
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
          onClick={() => openDeleteRegionModal(region, region.id)}
          className={`${actionBtn} bg-bg-elevated hover:bg-error-bg text-text-secondary hover:text-error-text`}
          title="Delete region"
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
