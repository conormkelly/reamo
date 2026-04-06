/**
 * Region Info Bar Component
 *
 * Inline editing panel for the selected region in regions mode.
 * All edits go directly to REAPER via WebSocket — no staging/pending changes.
 *
 * Layout (horizontal):
 *   Row 1: Color: [■] | Name: Verse 1 ............ [⊕] [🗑] [+]
 *   Row 2: Start: 1.1 | End: 5.1 | Length: 4.0
 *
 * Color: tap swatch = OS color picker, hold = reset to default.
 * Name/Start/Length: tap to edit inline.
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { Plus, Trash2, CopyPlus, Crosshair } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useTimeFormatters } from '../../hooks';
import { hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';
import type { Region } from '../../core/types';
import { useReaper } from '../ReaperProvider';
import { region as regionCmd, tempo as tempoCmd, timeSelection } from '../../core/WebSocketCommands';
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
  const { sendCommand, sendCommandAsync } = useReaper();
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const selectedRegionIds = useReaperStore((s) => s.selectedRegionIds);
  const regions = useReaperStore((s) => s.regions);

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

  const inputRef = useRef<HTMLInputElement>(null);

  // Color swatch: tap = OS picker, hold = reset
  const colorInputRef = useRef<HTMLInputElement>(null);
  const colorHoldTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const colorDidResetRef = useRef(false);

  // Delete confirmation (tap once = red, tap again = delete)
  const [confirmDelete, setConfirmDelete] = useState(false);
  const deleteTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Long-press for clone
  const longPressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
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

  // Reset delete confirmation when selection changes
  useEffect(() => {
    setConfirmDelete(false);
    if (deleteTimeoutRef.current) { clearTimeout(deleteTimeoutRef.current); deleteTimeoutRef.current = null; }
  }, [selectedRegionIds]);

  // Cleanup timers on unmount
  useEffect(() => {
    return () => {
      if (longPressTimerRef.current) clearTimeout(longPressTimerRef.current);
      if (colorHoldTimerRef.current) clearTimeout(colorHoldTimerRef.current);
      if (deleteTimeoutRef.current) clearTimeout(deleteTimeoutRef.current);
    };
  }, []);

  // Only show in regions mode
  if (timelineMode !== 'regions') return null;

  const selectedId = selectedRegionIds.length === 1 ? selectedRegionIds[0] : null;
  const region: Region | undefined = selectedId !== null
    ? regions.find(r => r.id === selectedId)
    : undefined;

  // Bar strings directly from server-provided region data
  const displayStartBars = region?.startBars ?? (region ? formatBeats(region.start) : '');
  const displayEndBars = region?.endBars ?? (region ? formatBeats(region.end) : '');
  const displayLengthBars = region?.lengthBars ?? (region ? formatDuration(region.end - region.start) : '');

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
      if (editValue.trim()) {
        sendCommand(regionCmd.update(editRegion.id, { name: editValue.trim() }));
      }
    } else if (bpm) {
      if (editingField === 'start') {
        const parsed = parseBarsString(editValue) ?? parseBarsString(editValue + '.1');
        if (parsed) {
          try {
            const response = await sendCommandAsync(tempoCmd.barsToTime(parsed.bar, parsed.beat, parsed.ticks));
            const resp = response as { payload?: { time?: number } } | undefined;
            if (resp?.payload?.time !== undefined && resp.payload.time >= 0 && resp.payload.time < editRegion.end) {
              sendCommand(regionCmd.update(editRegion.id, { start: resp.payload.time }));
            }
          } catch {
            const newSeconds = parseBarBeat(editValue);
            if (newSeconds !== null && newSeconds >= 0 && newSeconds < editRegion.end) {
              sendCommand(regionCmd.update(editRegion.id, { start: newSeconds }));
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
              sendCommand(regionCmd.update(editRegion.id, { end: resp.payload.time }));
            }
          } catch {
            const newDuration = parseDuration(editValue);
            if (newDuration !== null && newDuration > 0) {
              sendCommand(regionCmd.update(editRegion.id, { end: editRegion.start + newDuration }));
            }
          }
        } else {
          const newDuration = parseDuration(editValue);
          if (newDuration !== null && newDuration > 0) {
            sendCommand(regionCmd.update(editRegion.id, { end: editRegion.start + newDuration }));
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
      sendCommand(regionCmd.update(region.id, { color: 0 }));
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
    sendCommand(regionCmd.update(region.id, { color: hexToReaperColor(hex) }));
  };

  // --- Delete (tap once = confirm, tap again = delete) ---

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

  // --- Set time selection to region bounds ---

  const handleSetTimeSelection = () => {
    if (!region) return;
    sendCommand(timeSelection.set(region.start, region.end));
  };

  // --- Clone ---

  const handleCloneRegion = () => {
    if (!region) return;
    const lastEnd = regions.length > 0 ? Math.max(...regions.map(r => r.end)) : 0;
    const duration = region.end - region.start;
    sendCommand(regionCmd.add(lastEnd, lastEnd + duration, region.name, region.color));
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
  if (regions.length === 0) {
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
        onClick={handleSetTimeSelection}
        className={`${actionBtn} text-text-tertiary hover:text-accent-region hover:bg-bg-elevated`}
        title="Set time selection to region"
      >
        <Crosshair size={16} />
      </button>
      <button
        onClick={handleDelete}
        className={`${actionBtn} ${
          confirmDelete
            ? 'bg-error-bg text-error-text'
            : 'text-text-tertiary hover:text-error-text hover:bg-error-bg'
        }`}
        title={confirmDelete ? 'Tap again to confirm delete' : 'Delete region'}
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
      <div className={`flex flex-col gap-3 px-3 py-2 text-sm ${className}`}>
        {/* Color: [■] */}
        <div className="flex items-center gap-1.5">
          <span className="text-text-secondary text-xs flex-shrink-0">Color:</span>
          {colorSwatch}
        </div>

        {/* Name: ... */}
        <div className="flex items-center gap-1.5 min-w-0">
          <span className="text-text-secondary text-xs flex-shrink-0">Name:</span>
          {nameField}
        </div>

        {/* Start: 1.1 */}
        <div className="flex items-center gap-1.5 font-mono text-xs">
          <span className="text-text-secondary font-sans">Start:</span>
          {startField}
        </div>

        {/* End: 5.1 */}
        <div className="flex items-center gap-1.5 font-mono text-xs">
          <span className="text-text-secondary font-sans">End:</span>
          <span className="text-text-tertiary px-1 py-0.5">{endDisplay}</span>
        </div>

        {/* Length: 4.0 */}
        <div className="flex items-center gap-1.5 font-mono text-xs">
          <span className="text-text-secondary font-sans">Length:</span>
          {lengthField}
        </div>

        {/* actions */}
        {actionButtons}
      </div>
    );
  }

  // --- Horizontal layout (portrait SecondaryPanel) ---
  return (
    <div className={`flex flex-col gap-3 px-3 py-2 text-sm ${className}`}>
      {/* Row 1: Color: [■] | Name: Verse 1 ............ [actions] */}
      <div className="flex items-center gap-3 min-w-0">
        <div className="flex items-center gap-1.5 flex-shrink-0">
          <span className="text-text-secondary text-xs flex-shrink-0">Color:</span>
          {colorSwatch}
        </div>

        <div className="w-px h-4 bg-border-default flex-shrink-0" />

        <div className="flex items-center gap-1.5 flex-1 min-w-0">
          <span className="text-text-secondary text-xs flex-shrink-0">Name:</span>
          {nameField}
        </div>

        {actionButtons}
      </div>

      {/* Row 2: Start: 1.1 | End: 5.1 | Length: 4.0 */}
      <div className="flex items-center gap-3 min-h-[32px]">
        <div className="flex items-center gap-1.5 font-mono text-xs">
          <span className="text-text-secondary font-sans">Start:</span>
          {startField}
        </div>

        <div className="w-px h-4 bg-border-default flex-shrink-0" />

        <div className="flex items-center gap-1.5 font-mono text-xs">
          <span className="text-text-secondary font-sans">End:</span>
          <span className="text-text-tertiary px-1 py-0.5">{endDisplay}</span>
        </div>

        <div className="w-px h-4 bg-border-default flex-shrink-0" />

        <div className="flex items-center gap-1.5 font-mono text-xs">
          <span className="text-text-secondary font-sans">Length:</span>
          {lengthField}
        </div>
      </div>
    </div>
  );
}
