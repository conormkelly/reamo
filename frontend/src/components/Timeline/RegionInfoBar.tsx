/**
 * Region Info Bar Component
 *
 * Designed for the SecondaryPanel info tab. No labels, no nested cards.
 * The format IS the label: color swatch is the color, monospace "1.1 → 5.1" is start→end.
 *
 * Layout when region selected:
 *   [■] Verse 1 ············ [🗑] [+]
 *   1.1 → 5.1 · 4.0
 *
 * Empty states:
 *   "Select a region to edit"  [+]
 *   "Add a region"  [+]
 *
 * Color: tap swatch = OS color picker, hold = reset to default.
 * Name/Start/Length: tap to edit inline.
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { Plus, Trash2, CopyPlus } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useTimeFormatters } from '../../hooks';
import { hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';
import type { Region } from '../../core/types';
import { useReaper } from '../ReaperProvider';
import { tempo as tempoCmd } from '../../core/WebSocketCommands';
import { DEFAULT_REGION_COLOR } from '../../constants/colors';

/**
 * Parse a bar.beat.ticks string (e.g., "13.1.00") into components
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

/**
 * Parse a duration string into bar/beat/ticks (bars start at 0 for durations)
 */
function parseDurationBars(input: string): { bar: number; beat: number; ticks: number } | null {
  const trimmed = input.trim();
  if (!trimmed) return null;
  const parts = trimmed.split('.');
  const bar = parseInt(parts[0], 10);
  if (isNaN(bar)) return null;
  const beat = parts.length >= 2 ? parseInt(parts[1], 10) : 0;
  const ticks = parts.length >= 3 ? parseInt(parts[2], 10) : 0;
  if (isNaN(beat) || isNaN(ticks)) return null;
  return { bar, beat, ticks };
}

/**
 * Add duration to a position (with carry for beats/ticks)
 */
function addDurationToPosition(
  pos: { bar: number; beat: number; ticks: number },
  dur: { bar: number; beat: number; ticks: number },
  beatsPerBar: number
): { bar: number; beat: number; ticks: number } {
  let ticks = pos.ticks + dur.ticks;
  let beat = pos.beat + dur.beat;
  let bar = pos.bar + dur.bar;
  if (ticks >= 100) { beat += Math.floor(ticks / 100); ticks = ticks % 100; }
  while (beat > beatsPerBar) { beat -= beatsPerBar; bar += 1; }
  return { bar, beat, ticks };
}

interface RegionInfoBarProps {
  className?: string;
  onAddRegion?: () => void;
  /** Layout mode — 'horizontal' for SecondaryPanel, 'vertical' for landscape sidebar */
  layout?: 'horizontal' | 'vertical';
}

type EditingField = 'name' | 'start' | 'length' | null;

const COLOR_HOLD_DURATION = 500;

export function RegionInfoBar({ className = '', onAddRegion, layout = 'horizontal' }: RegionInfoBarProps): ReactElement | null {
  const { sendCommandAsync } = useReaper();
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const selectedRegionIds = useReaperStore((s) => s.selectedRegionIds);
  const regions = useReaperStore((s) => s.regions);
  const pendingChanges = useReaperStore((s) => s.pendingChanges);
  const getDisplayRegions = useReaperStore((s) => s.getDisplayRegions);
  const updateRegionBounds = useReaperStore((s) => s.updateRegionBounds);
  const updateRegionMeta = useReaperStore((s) => s.updateRegionMeta);
  const createRegion = useReaperStore((s) => s.createRegion);
  const selectRegion = useReaperStore((s) => s.selectRegion);
  const nextNewRegionKey = useReaperStore((s) => s.nextNewRegionKey);
  const openDeleteRegionModal = useReaperStore((s) => s.openDeleteRegionModal);

  const {
    formatBeats,
    formatDuration,
    parseBarBeat,
    parseDuration,
    bpm,
    beatsPerBar,
  } = useTimeFormatters();

  const [editingField, setEditingField] = useState<EditingField>(null);
  const [editValue, setEditValue] = useState('');
  const editingRegionDataRef = useRef<{
    id: number;
    start: number;
    end: number;
    startBars?: string;
    name: string;
  } | null>(null);

  const [pendingBarStrings, setPendingBarStrings] = useState<Record<string, { startBars: string; endBars: string; lengthBars: string }>>({});
  const inputRef = useRef<HTMLInputElement>(null);

  // Color swatch: tap = OS picker, hold = reset
  const colorInputRef = useRef<HTMLInputElement>(null);
  const colorHoldTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const colorDidResetRef = useRef(false);

  // Long-press for clone
  const longPressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const selectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isLongPressRef = useRef(false);
  const addButtonRef = useRef<HTMLButtonElement>(null);
  const [isCloneMode, setIsCloneMode] = useState(false);
  const LONG_PRESS_DURATION = 500;

  // Focus input when editing starts
  useEffect(() => {
    if (editingField && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [editingField]);

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

          setPendingBarStrings(prev => ({ ...prev, [cacheKey]: { startBars, endBars, lengthBars } }));
        }
      } catch {
        // Ignore — falls back to local calculation
      }
    });
  }, [pendingChanges, pendingBarStrings, sendCommandAsync, beatsPerBar]);

  // Cleanup timers on unmount
  useEffect(() => {
    return () => {
      if (longPressTimerRef.current) clearTimeout(longPressTimerRef.current);
      if (selectTimerRef.current) clearTimeout(selectTimerRef.current);
      if (colorHoldTimerRef.current) clearTimeout(colorHoldTimerRef.current);
    };
  }, []);

  // Only show in regions mode
  if (timelineMode !== 'regions') return null;

  const displayRegions = getDisplayRegions(regions);
  const selectedId = selectedRegionIds.length === 1 ? selectedRegionIds[0] : null;
  const region: Region | undefined = selectedId !== null
    ? displayRegions.find(r => r.id === selectedId)
    : undefined;

  // Pending bar strings
  const pendingChange = selectedId !== null ? pendingChanges[selectedId] : null;
  const hasPending = pendingChange !== null && pendingChange !== undefined;
  const pendingCacheKey = hasPending && region ? `${selectedId}:${region.start}:${region.end}` : null;
  const fetchedBars = pendingCacheKey ? pendingBarStrings[pendingCacheKey] : null;

  const displayStartBars = fetchedBars?.startBars ?? region?.startBars ?? (region ? formatBeats(region.start) : '');
  const displayEndBars = fetchedBars?.endBars ?? region?.endBars ?? (region ? formatBeats(region.end) : '');
  const displayLengthBars = fetchedBars?.lengthBars ?? region?.lengthBars ?? (region ? formatDuration(region.end - region.start) : '');

  const currentColor = region ? reaperColorToHexWithFallback(region.color, DEFAULT_REGION_COLOR) : DEFAULT_REGION_COLOR;
  const isDefaultColor = !region?.color || region.color === 0;

  // --- Field editing ---

  const handleFieldClick = (field: EditingField) => {
    if (!region) return;
    editingRegionDataRef.current = {
      id: region.id, start: region.start, end: region.end,
      startBars: displayStartBars || undefined, name: region.name,
    };

    if (!bpm && (field === 'start' || field === 'length')) return;

    setEditingField(field);
    if (field === 'name') setEditValue(region.name);
    else if (field === 'start') setEditValue(displayStartBars.replace(/\.00$/, ''));
    else if (field === 'length') setEditValue(displayLengthBars.replace(/\.00$/, ''));
  };

  const handleConfirm = async () => {
    const editRegion = editingRegionDataRef.current;
    if (!editRegion || !editingField) {
      setEditingField(null); setEditValue(''); editingRegionDataRef.current = null;
      return;
    }

    if (editingField === 'name') {
      if (editValue.trim()) updateRegionMeta(editRegion.id, { name: editValue.trim() }, regions);
    } else if (bpm) {
      if (editingField === 'start') {
        const parsed = parseBarsString(editValue) ?? parseBarsString(editValue + '.1');
        if (parsed) {
          try {
            const response = await sendCommandAsync(tempoCmd.barsToTime(parsed.bar, parsed.beat, parsed.ticks));
            const resp = response as { payload?: { time?: number } } | undefined;
            if (resp?.payload?.time !== undefined && resp.payload.time >= 0 && resp.payload.time < editRegion.end) {
              updateRegionBounds(editRegion.id, { start: resp.payload.time }, regions);
            }
          } catch {
            const newSeconds = parseBarBeat(editValue);
            if (newSeconds !== null && newSeconds >= 0 && newSeconds < editRegion.end) {
              updateRegionBounds(editRegion.id, { start: newSeconds }, regions);
            }
          }
        }
      } else if (editingField === 'length') {
        const durParsed = parseDurationBars(editValue);
        const startParsed = editRegion.startBars ? parseBarsString(editRegion.startBars) : null;

        if (durParsed && startParsed) {
          const newEnd = addDurationToPosition(startParsed, durParsed, beatsPerBar);
          try {
            const response = await sendCommandAsync(tempoCmd.barsToTime(newEnd.bar, newEnd.beat, newEnd.ticks));
            const resp = response as { payload?: { time?: number } } | undefined;
            if (resp?.payload?.time !== undefined && resp.payload.time > editRegion.start) {
              updateRegionBounds(editRegion.id, { end: resp.payload.time }, regions);
            }
          } catch {
            const newDuration = parseDuration(editValue);
            if (newDuration !== null && newDuration > 0) {
              updateRegionBounds(editRegion.id, { end: editRegion.start + newDuration }, regions);
            }
          }
        } else {
          const newDuration = parseDuration(editValue);
          if (newDuration !== null && newDuration > 0) {
            updateRegionBounds(editRegion.id, { end: editRegion.start + newDuration }, regions);
          }
        }
      }
    }

    setEditingField(null); setEditValue(''); editingRegionDataRef.current = null;
  };

  const handleCancel = () => {
    setEditingField(null); setEditValue(''); editingRegionDataRef.current = null;
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') { e.preventDefault(); handleConfirm(); }
    else if (e.key === 'Escape') { e.preventDefault(); handleCancel(); }
  };

  // --- Color swatch: tap = OS picker, hold = reset ---

  const handleColorPointerDown = () => {
    if (!region) return;
    colorDidResetRef.current = false;
    colorHoldTimerRef.current = setTimeout(() => {
      colorDidResetRef.current = true;
      updateRegionMeta(region.id, { color: 0 }, regions);
    }, COLOR_HOLD_DURATION);
  };

  const handleColorPointerUp = () => {
    if (colorHoldTimerRef.current) { clearTimeout(colorHoldTimerRef.current); colorHoldTimerRef.current = null; }
    if (!colorDidResetRef.current) colorInputRef.current?.click();
  };

  const handleColorPointerCancel = () => {
    if (colorHoldTimerRef.current) { clearTimeout(colorHoldTimerRef.current); colorHoldTimerRef.current = null; }
  };

  const handleColorChange = (hex: string) => {
    if (!region) return;
    updateRegionMeta(region.id, { color: hexToReaperColor(hex) }, regions);
  };

  // --- Clone ---

  const handleCloneRegion = () => {
    if (!region || !bpm) return;
    const lastEnd = displayRegions.length > 0 ? Math.max(...displayRegions.map(r => r.end)) : 0;
    const duration = region.end - region.start;
    const newRegionKey = nextNewRegionKey;
    createRegion(lastEnd, lastEnd + duration, region.name, bpm, region.color, regions);
    selectTimerRef.current = setTimeout(() => selectRegion(newRegionKey), 0);
  };

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
    if (isLongPressRef.current && region) handleCloneRegion();
    else if (!isLongPressRef.current && onAddRegion) onAddRegion();
    setIsCloneMode(false);
  };

  const handleAddPointerLeave = () => {
    if (longPressTimerRef.current) { clearTimeout(longPressTimerRef.current); longPressTimerRef.current = null; }
    isLongPressRef.current = false;
    setIsCloneMode(false);
  };

  // --- Render ---

  const actionBtn = 'p-1.5 rounded transition-colors';

  // No regions at all
  if (displayRegions.length === 0) {
    return (
      <div className={`flex items-center gap-2 px-3 py-2 ${className}`}>
        <span className="text-text-muted text-sm flex-1">Add a region</span>
        {onAddRegion && (
          <button onClick={onAddRegion} className={`${actionBtn} bg-accent-region text-text-primary`} title="Add region">
            <Plus size={18} />
          </button>
        )}
      </div>
    );
  }

  // No region selected
  if (!region) {
    return (
      <div className={`flex items-center gap-2 px-3 py-2 ${className}`}>
        <span className="text-text-muted text-sm flex-1">Select a region to edit</span>
        {onAddRegion && (
          <button onClick={onAddRegion} className={`${actionBtn} bg-accent-region text-text-primary`} title="Add region">
            <Plus size={18} />
          </button>
        )}
      </div>
    );
  }

  // Strip trailing .00 for compact display
  const startDisplay = displayStartBars.replace(/\.00$/, '');
  const endDisplay = displayEndBars.replace(/\.00$/, '');
  const lengthDisplay = displayLengthBars.replace(/\.00$/, '');

  // Shared sub-components used by both layouts
  const colorSwatch = (
    <div
      onPointerDown={handleColorPointerDown}
      onPointerUp={handleColorPointerUp}
      onPointerLeave={handleColorPointerCancel}
      onPointerCancel={handleColorPointerCancel}
      className="relative w-6 h-6 rounded-sm border border-border-default cursor-pointer flex-shrink-0 touch-none"
      style={{ backgroundColor: currentColor }}
      title={isDefaultColor ? 'Tap to pick color' : 'Tap to change, hold to reset'}
    >
      {!isDefaultColor && (
        <div className="absolute -top-0.5 -right-0.5 w-2 h-2 bg-primary-hover rounded-full" />
      )}
      <input
        ref={colorInputRef}
        type="color"
        value={currentColor}
        onChange={(e) => handleColorChange(e.target.value)}
        className="absolute inset-0 opacity-0 cursor-pointer"
        tabIndex={-1}
      />
    </div>
  );

  const nameField = editingField === 'name' ? (
    <input
      ref={inputRef}
      type="text"
      value={editValue}
      onChange={(e) => setEditValue(e.target.value)}
      onKeyDown={handleKeyDown}
      onBlur={handleConfirm}
      className="flex-1 min-w-0 px-1.5 py-0.5 bg-bg-elevated border border-accent-region rounded text-text-primary text-base focus:outline-none focus:ring-1 focus:ring-accent-region"
    />
  ) : (
    <button
      onClick={() => handleFieldClick('name')}
      className="text-text-primary font-medium text-sm truncate min-w-0 flex-1 text-left px-1 py-0.5 rounded hover:bg-bg-elevated transition-colors"
    >
      {region.name}
    </button>
  );

  const startField = editingField === 'start' ? (
    <input
      ref={inputRef}
      type="text"
      value={editValue}
      onChange={(e) => setEditValue(e.target.value)}
      onKeyDown={handleKeyDown}
      onBlur={handleConfirm}
      className="w-20 px-1 py-0.5 bg-bg-elevated border border-accent-region rounded text-text-primary text-base font-mono focus:outline-none focus:ring-1 focus:ring-accent-region"
    />
  ) : (
    <button
      onClick={() => handleFieldClick('start')}
      className="text-text-secondary hover:bg-bg-elevated px-1 py-0.5 rounded transition-colors"
    >
      {startDisplay}
    </button>
  );

  const lengthField = editingField === 'length' ? (
    <input
      ref={inputRef}
      type="text"
      value={editValue}
      onChange={(e) => setEditValue(e.target.value)}
      onKeyDown={handleKeyDown}
      onBlur={handleConfirm}
      className="w-20 px-1 py-0.5 bg-bg-elevated border border-accent-region rounded text-text-primary text-base font-mono focus:outline-none focus:ring-1 focus:ring-accent-region"
    />
  ) : (
    <button
      onClick={() => handleFieldClick('length')}
      className="text-accent-region-hover hover:bg-bg-elevated px-1 py-0.5 rounded transition-colors"
    >
      {lengthDisplay}
    </button>
  );

  const actionButtons = (
    <div className="flex items-center gap-0.5 flex-shrink-0">
      <button
        onClick={() => openDeleteRegionModal(region, region.id)}
        className={`${actionBtn} text-text-tertiary hover:text-error-text hover:bg-error-bg`}
        title="Delete region"
      >
        <Trash2 size={16} />
      </button>
      {onAddRegion && (
        <button
          ref={addButtonRef}
          onPointerDown={handleAddPointerDown}
          onPointerUp={handleAddPointerUp}
          onPointerLeave={handleAddPointerLeave}
          onPointerCancel={handleAddPointerLeave}
          className={`${actionBtn} touch-none ${
            isCloneMode
              ? 'text-text-on-success bg-success-action'
              : 'text-accent-region hover:bg-bg-elevated'
          }`}
          title="Tap to add, hold to clone"
        >
          {isCloneMode ? <CopyPlus size={16} /> : <Plus size={16} />}
        </button>
      )}
    </div>
  );

  // --- Vertical layout (landscape sidebar) ---
  if (layout === 'vertical') {
    return (
      <div className={`flex flex-col gap-2 px-3 py-2 text-sm ${className}`}>
        {/* [swatch] name */}
        <div className="flex items-center gap-2 min-w-0">
          {colorSwatch}
          {nameField}
        </div>

        {/* start → end */}
        <div className="flex items-center gap-1.5 font-mono text-xs">
          {startField}
          <span className="text-text-muted">→</span>
          <span className="text-text-tertiary px-1 py-0.5">{endDisplay}</span>
        </div>

        {/* length */}
        <div className="font-mono text-xs">
          {lengthField}
        </div>

        {/* actions */}
        {actionButtons}
      </div>
    );
  }

  // --- Horizontal layout (portrait SecondaryPanel) ---
  return (
    <div className={`flex flex-col gap-1.5 px-3 py-2 text-sm ${className}`}>
      {/* Row 1: [swatch] name ............ [actions] */}
      <div className="flex items-center gap-2 min-w-0">
        {colorSwatch}
        {nameField}
        {actionButtons}
      </div>

      {/* Row 2: start → end · length — the format is the label */}
      <div className="flex items-center gap-1.5 font-mono text-xs pl-8">
        {startField}
        <span className="text-text-muted">→</span>
        <span className="text-text-tertiary px-1 py-0.5">{endDisplay}</span>
        <span className="text-text-muted">·</span>
        {lengthField}
      </div>
    </div>
  );
}
