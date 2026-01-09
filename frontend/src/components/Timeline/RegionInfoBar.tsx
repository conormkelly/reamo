/**
 * Region Info Bar Component
 * Shows name, start/end position, length, and color when a region is selected
 * Fields are tappable to edit values directly
 * Includes "Add Region" button for creating new regions
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { Plus, Trash2, CopyPlus, RotateCcw } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useTimeFormatters } from '../../hooks';
import { hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';
import type { Region } from '../../core/types';
import { DeleteRegionModal } from './DeleteRegionModal';
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
 * Parse a duration string (e.g., "10", "10.1", "10.1.50") into bar/beat/ticks
 * For duration, bars start at 0 (not 1-indexed like positions)
 */
function parseDurationBars(input: string): { bar: number; beat: number; ticks: number } | null {
  const trimmed = input.trim();
  if (!trimmed) return null;

  const parts = trimmed.split('.');
  const bar = parseInt(parts[0], 10);
  if (isNaN(bar)) return null;

  // Default beat and ticks to 0 for durations
  const beat = parts.length >= 2 ? parseInt(parts[1], 10) : 0;
  const ticks = parts.length >= 3 ? parseInt(parts[2], 10) : 0;

  if (isNaN(beat) || isNaN(ticks)) return null;
  return { bar, beat, ticks };
}

/**
 * Add duration to a position (with carry for beats/ticks)
 * Returns the new position bar.beat.ticks
 */
function addDurationToPosition(
  pos: { bar: number; beat: number; ticks: number },
  dur: { bar: number; beat: number; ticks: number },
  beatsPerBar: number
): { bar: number; beat: number; ticks: number } {
  let ticks = pos.ticks + dur.ticks;
  let beat = pos.beat + dur.beat;
  let bar = pos.bar + dur.bar;

  // Carry ticks -> beat
  if (ticks >= 100) {
    beat += Math.floor(ticks / 100);
    ticks = ticks % 100;
  }

  // Carry beat -> bar (beat is 1-indexed in positions, so > beatsPerBar means carry)
  while (beat > beatsPerBar) {
    beat -= beatsPerBar;
    bar += 1;
  }

  return { bar, beat, ticks };
}

interface RegionInfoBarProps {
  className?: string;
  onAddRegion?: () => void;
}

type EditingField = 'name' | 'start' | 'length' | 'color' | null;

export function RegionInfoBar({ className = '', onAddRegion }: RegionInfoBarProps): ReactElement | null {
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
  // Store region data at edit start to avoid issues when selection changes during edit
  const editingRegionDataRef = useRef<{
    id: number;
    start: number;
    end: number;
    startBars?: string;
    name: string;
  } | null>(null);
  const [showColorPicker, setShowColorPicker] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  // Cache of bar strings fetched for pending regions (keyed by "id:start:end")
  const [pendingBarStrings, setPendingBarStrings] = useState<Record<string, { startBars: string; endBars: string; lengthBars: string }>>({});
  const inputRef = useRef<HTMLInputElement>(null);
  const colorPickerRef = useRef<HTMLDivElement>(null);

  // Long-press handling for clone functionality
  const longPressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isLongPressRef = useRef(false);
  const addButtonRef = useRef<HTMLButtonElement>(null);
  const [isCloneMode, setIsCloneMode] = useState(false);
  const LONG_PRESS_DURATION = 500; // ms

  // Focus input when editing starts (must be before any early returns)
  useEffect(() => {
    if (editingField && editingField !== 'color' && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [editingField]);

  // Fetch bar strings for pending regions (they don't have server bar strings)
  // This ensures accurate display regardless of playhead position
  useEffect(() => {
    const pendingIds = Object.keys(pendingChanges).map(k => parseInt(k, 10));
    if (pendingIds.length === 0) {
      // Clear cache when no pending changes
      if (Object.keys(pendingBarStrings).length > 0) {
        setPendingBarStrings({});
      }
      return;
    }

    // Fetch bar strings for each pending change
    pendingIds.forEach(async (id) => {
      const change = pendingChanges[id];
      if (!change || change.isDeleted) return;

      const cacheKey = `${id}:${change.newStart}:${change.newEnd}`;
      if (pendingBarStrings[cacheKey]) return; // Already fetched

      try {
        // Fetch start, end, and calculate length bar strings
        const [startResp, endResp] = await Promise.all([
          sendCommandAsync(tempoCmd.timeToBeats(change.newStart)),
          sendCommandAsync(tempoCmd.timeToBeats(change.newEnd)),
        ]);

        const startData = startResp as { payload?: { bars?: string } } | undefined;
        const endData = endResp as { payload?: { bars?: string } } | undefined;

        if (startData?.payload?.bars && endData?.payload?.bars) {
          // Extract to local variables for TypeScript narrowing
          const startBars = startData.payload.bars;
          const endBars = endData.payload.bars;

          // Parse start and end to calculate length
          const startParsed = parseBarsString(startBars);
          const endParsed = parseBarsString(endBars);

          let lengthBars = '';
          if (startParsed && endParsed) {
            // Calculate length as bar.beat.ticks difference
            let barDiff = endParsed.bar - startParsed.bar;
            let beatDiff = endParsed.beat - startParsed.beat;
            let ticksDiff = endParsed.ticks - startParsed.ticks;

            // Handle borrows
            if (ticksDiff < 0) {
              beatDiff -= 1;
              ticksDiff += 100;
            }
            if (beatDiff < 0) {
              barDiff -= 1;
              beatDiff += beatsPerBar; // This is approximate, but better than playhead BPM
            }

            lengthBars = `${barDiff}.${beatDiff}.${ticksDiff.toString().padStart(2, '0')}`;
          }

          setPendingBarStrings(prev => ({
            ...prev,
            [cacheKey]: {
              startBars,
              endBars,
              lengthBars,
            },
          }));
        }
      } catch {
        // Ignore errors, will fall back to local calculation
      }
    });
  }, [pendingChanges, pendingBarStrings, sendCommandAsync, beatsPerBar]);

  // Close color picker when clicking outside
  useEffect(() => {
    if (!showColorPicker) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (colorPickerRef.current && !colorPickerRef.current.contains(e.target as Node)) {
        setShowColorPicker(false);
        setEditingField(null);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showColorPicker]);

  // Only show in regions mode
  if (timelineMode !== 'regions') {
    return null;
  }

  // Get display regions (with pending changes)
  const displayRegions = getDisplayRegions(regions);
  // Find the selected region by ID (stable across server updates)
  const selectedId = selectedRegionIds.length === 1 ? selectedRegionIds[0] : null;
  const region: Region | undefined = selectedId !== null
    ? displayRegions.find(r => r.id === selectedId)
    : undefined;

  // Check if selected region has pending changes (no server bar strings)
  const pendingChange = selectedId !== null ? pendingChanges[selectedId] : null;
  const hasPendingChanges = pendingChange !== null && pendingChange !== undefined;

  // Get fetched bar strings for pending region (if available)
  const pendingCacheKey = hasPendingChanges && region ? `${selectedId}:${region.start}:${region.end}` : null;
  const fetchedPendingBars = pendingCacheKey ? pendingBarStrings[pendingCacheKey] : null;

  // Display bar strings: prefer fetched pending bars, then server bars, then local calculation
  const displayStartBars = fetchedPendingBars?.startBars ?? region?.startBars ?? (region ? formatBeats(region.start) : '');
  const displayEndBars = fetchedPendingBars?.endBars ?? region?.endBars ?? (region ? formatBeats(region.end) : '');
  const displayLengthBars = fetchedPendingBars?.lengthBars ?? region?.lengthBars ?? (region ? formatDuration(region.end - region.start) : '');

  // Get unique colors from all regions for the picker
  const existingColors = new Set<string>();
  displayRegions.forEach((r) => {
    if (r.color) {
      existingColors.add(reaperColorToHexWithFallback(r.color, DEFAULT_REGION_COLOR));
    }
  });

  const currentColor = region ? reaperColorToHexWithFallback(region.color, DEFAULT_REGION_COLOR) : DEFAULT_REGION_COLOR;

  const handleFieldClick = (field: EditingField) => {
    if (!region) return;

    // Capture region data at edit start to use in handleConfirm
    // This prevents issues when selection changes during edit
    // Use display bar strings which include fetched pending bar strings
    editingRegionDataRef.current = {
      id: region.id,
      start: region.start,
      end: region.end,
      startBars: displayStartBars || undefined,
      name: region.name,
    };

    if (field === 'color') {
      setShowColorPicker(true);
      setEditingField('color');
      return;
    }

    if (!bpm && (field === 'start' || field === 'length')) return;

    setEditingField(field);
    if (field === 'name') {
      setEditValue(region.name);
    } else if (field === 'start') {
      // Use display bar string (fetched pending or server), stripping trailing .00 ticks for easier editing
      setEditValue(displayStartBars.replace(/\.00$/, ''));
    } else if (field === 'length') {
      // Use display bar string (fetched pending or server), stripping trailing .00 ticks for easier editing
      setEditValue(displayLengthBars.replace(/\.00$/, ''));
    }
  };

  // Check if region uses default color (color = 0 or undefined)
  const isDefaultColor = !region?.color || region.color === 0;

  const handleColorSelect = (hex: string) => {
    // Use captured region ID to ensure we update the right region
    const editRegion = editingRegionDataRef.current;
    if (!editRegion) return;
    const reaperColor = hexToReaperColor(hex);
    updateRegionMeta(editRegion.id, { color: reaperColor }, regions);
    setShowColorPicker(false);
    setEditingField(null);
    editingRegionDataRef.current = null;
  };

  const handleColorReset = () => {
    // Use captured region ID to ensure we update the right region
    const editRegion = editingRegionDataRef.current;
    if (!editRegion) return;
    // Send 0 to reset to REAPER's default region color
    updateRegionMeta(editRegion.id, { color: 0 }, regions);
    setShowColorPicker(false);
    setEditingField(null);
    editingRegionDataRef.current = null;
  };

  const handleConfirm = async () => {
    // Use the captured region data from when editing started
    // This prevents applying changes to wrong region if selection changed
    const editRegion = editingRegionDataRef.current;
    if (!editRegion || !editingField) {
      setEditingField(null);
      setEditValue('');
      editingRegionDataRef.current = null;
      return;
    }

    if (editingField === 'name') {
      if (editValue.trim()) {
        updateRegionMeta(editRegion.id, { name: editValue.trim() }, regions);
      }
    } else if (bpm) {
      if (editingField === 'start') {
        // Parse bar.beat.ticks and convert to time via server (no ripple, no snapping)
        const parsed = parseBarsString(editValue) ?? parseBarsString(editValue + '.1'); // Handle "13" -> "13.1"
        if (parsed) {
          try {
            const response = await sendCommandAsync(tempoCmd.barsToTime(parsed.bar, parsed.beat, parsed.ticks));
            const resp = response as { payload?: { time?: number } } | undefined;
            if (resp?.payload?.time !== undefined && resp.payload.time >= 0 && resp.payload.time < editRegion.end) {
              updateRegionBounds(editRegion.id, { start: resp.payload.time }, regions);
            }
          } catch {
            // Fall back to local parsing
            const newSeconds = parseBarBeat(editValue);
            if (newSeconds !== null && newSeconds >= 0 && newSeconds < editRegion.end) {
              updateRegionBounds(editRegion.id, { start: newSeconds }, regions);
            }
          }
        }
      } else if (editingField === 'length') {
        // Parse duration as bar.beat.ticks (no ripple, no snapping)
        const durParsed = parseDurationBars(editValue);
        // Parse start position from server's startBars (captured at edit start)
        const startParsed = editRegion.startBars ? parseBarsString(editRegion.startBars) : null;

        if (durParsed && startParsed) {
          // Add duration to start position to get new end position
          const newEnd = addDurationToPosition(startParsed, durParsed, beatsPerBar);

          try {
            // Convert new end bar.beat.ticks to time via server
            const response = await sendCommandAsync(tempoCmd.barsToTime(newEnd.bar, newEnd.beat, newEnd.ticks));
            const resp = response as { payload?: { time?: number } } | undefined;
            if (resp?.payload?.time !== undefined && resp.payload.time > editRegion.start) {
              updateRegionBounds(editRegion.id, { end: resp.payload.time }, regions);
            }
          } catch {
            // Fall back to local parsing
            const newDuration = parseDuration(editValue);
            if (newDuration !== null && newDuration > 0) {
              const newEndTime = editRegion.start + newDuration;
              updateRegionBounds(editRegion.id, { end: newEndTime }, regions);
            }
          }
        } else {
          // Fall back to local parsing if we don't have startBars
          const newDuration = parseDuration(editValue);
          if (newDuration !== null && newDuration > 0) {
            const newEndTime = editRegion.start + newDuration;
            updateRegionBounds(editRegion.id, { end: newEndTime }, regions);
          }
        }
      }
    }

    setEditingField(null);
    setEditValue('');
    editingRegionDataRef.current = null;
  };

  const handleCancel = () => {
    setEditingField(null);
    setEditValue('');
    setShowColorPicker(false);
    editingRegionDataRef.current = null;
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleConfirm();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      handleCancel();
    }
  };

  // Clone selected region and place at end of last region
  const handleCloneRegion = () => {
    if (!region || !bpm) return;

    // Find end of last region in displayRegions
    const lastEnd = displayRegions.length > 0
      ? Math.max(...displayRegions.map(r => r.end))
      : 0;

    // Clone with same duration
    const cloneDuration = region.end - region.start;
    const start = lastEnd;
    const end = start + cloneDuration;

    // Store the key that will be used for the new region
    const newRegionKey = nextNewRegionKey;

    createRegion(start, end, region.name, bpm, region.color, regions);

    // Select the new region by its ID (the newRegionKey IS the ID for new regions)
    // We need to do this after state updates, so use setTimeout
    setTimeout(() => {
      selectRegion(newRegionKey);
    }, 0);
  };

  // Long-press handlers for Add button
  const handleAddPointerDown = () => {
    isLongPressRef.current = false;
    setIsCloneMode(false);

    // Only enable clone mode if a region is selected
    if (region) {
      longPressTimerRef.current = setTimeout(() => {
        isLongPressRef.current = true;
        setIsCloneMode(true);
      }, LONG_PRESS_DURATION);
    }
  };

  const handleAddPointerUp = () => {
    if (longPressTimerRef.current) {
      clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }

    // If it was a long press and we have a region, clone it
    if (isLongPressRef.current && region) {
      handleCloneRegion();
    } else if (!isLongPressRef.current && onAddRegion) {
      // Normal tap - open add modal
      onAddRegion();
    }

    setIsCloneMode(false);
  };

  const handleAddPointerLeave = () => {
    if (longPressTimerRef.current) {
      clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
    isLongPressRef.current = false;
    setIsCloneMode(false);
  };

  const handleAddPointerMove = (e: React.PointerEvent) => {
    // Cancel if pointer moves outside the button
    if (!addButtonRef.current) return;
    const rect = addButtonRef.current.getBoundingClientRect();
    const isOutside =
      e.clientX < rect.left ||
      e.clientX > rect.right ||
      e.clientY < rect.top ||
      e.clientY > rect.bottom;

    if (isOutside) {
      if (longPressTimerRef.current) {
        clearTimeout(longPressTimerRef.current);
        longPressTimerRef.current = null;
      }
      isLongPressRef.current = false;
      setIsCloneMode(false);
    }
  };

  // Cleanup long-press timer on unmount
  useEffect(() => {
    return () => {
      if (longPressTimerRef.current) {
        clearTimeout(longPressTimerRef.current);
      }
    };
  }, []);

  const renderField = (
    field: EditingField,
    label: string,
    value: string,
    colorClass: string = 'text-text-primary',
    inputWidth: string = 'w-20'
  ) => {
    const isEditing = editingField === field;

    return (
      <div className="flex items-center gap-1.5">
        <span className="text-text-secondary text-xs">{label}:</span>
        {isEditing ? (
          <input
            ref={inputRef}
            type="text"
            value={editValue}
            onChange={(e) => setEditValue(e.target.value)}
            onKeyDown={handleKeyDown}
            onBlur={handleConfirm}
            className={`${inputWidth} px-1.5 py-0.5 bg-bg-elevated border border-accent-region rounded text-text-primary font-mono text-xs focus:outline-none focus:ring-1 focus:ring-accent-region`}
          />
        ) : (
          <button
            onClick={() => handleFieldClick(field)}
            className={`${colorClass} font-mono text-xs hover:bg-bg-elevated px-1.5 py-0.5 rounded transition-colors cursor-pointer truncate max-w-24`}
          >
            {value}
          </button>
        )}
      </div>
    );
  };

  return (
    <div className={`flex items-center gap-2 ${className}`}>
      {/* Region info section */}
      <div className="flex flex-col gap-1 px-3 py-1.5 bg-bg-surface/50 rounded-lg text-sm flex-1 min-w-0">
        {region ? (
          <>
            {/* Line 1: Name and Color */}
            <div className="flex items-center gap-3">
              {/* Name */}
              {renderField('name', 'Name', region.name, 'text-text-primary font-medium', 'w-24')}

              <div className="w-px h-4 bg-border-default flex-shrink-0" />

              {/* Color */}
              <div className="flex items-center gap-1.5 relative">
                <span className="text-text-secondary text-xs">Color:</span>
                <button
                  onClick={() => handleFieldClick('color')}
                  className="w-6 h-6 rounded border-2 border-border-default hover:border-text-secondary transition-colors cursor-pointer"
                  style={{ backgroundColor: currentColor }}
                  title="Change color"
                />
                {showColorPicker && (
                  <div
                    ref={colorPickerRef}
                    className="absolute top-full left-0 mt-2 p-3 bg-bg-surface border border-border-default rounded-lg shadow-xl z-50 min-w-[200px]"
                  >
                    {/* Default + Project colors row */}
                    <div className="mb-3">
                      <div className="flex gap-2 overflow-x-auto pb-1 max-w-[200px] items-center">
                        {/* Default (reset) color - always first */}
                        <button
                          onClick={handleColorReset}
                          className={`w-6 h-6 rounded border-2 transition-all flex-shrink-0 relative ${
                            isDefaultColor
                              ? 'border-white scale-110'
                              : 'border-transparent hover:border-text-secondary'
                          }`}
                          style={{ backgroundColor: DEFAULT_REGION_COLOR }}
                          title="Reset to default"
                        >
                          <RotateCcw size={10} className="absolute inset-0 m-auto text-white/80" />
                        </button>

                        {/* Existing colors from project */}
                        {Array.from(existingColors).map((color) => (
                          <button
                            key={color}
                            onClick={() => handleColorSelect(color)}
                            className={`w-6 h-6 rounded border-2 transition-all flex-shrink-0 ${
                              !isDefaultColor && currentColor.toLowerCase() === color.toLowerCase()
                                ? 'border-white scale-110'
                                : 'border-transparent hover:border-text-secondary'
                            }`}
                            style={{ backgroundColor: color }}
                          />
                        ))}
                      </div>
                    </div>
                    {/* Color picker and hex input */}
                    <div className="text-xs text-text-secondary mb-1.5">Pick color</div>
                    <div className="flex gap-2 items-center">
                      <input
                        type="color"
                        value={currentColor}
                        onChange={(e) => handleColorSelect(e.target.value)}
                        className="w-8 h-8 rounded border-2 border-border-default cursor-pointer bg-transparent"
                        title="Pick a color"
                      />
                      <input
                        type="text"
                        placeholder="Default"
                        defaultValue={isDefaultColor ? '' : currentColor}
                        className="flex-1 px-2 py-1 bg-bg-elevated border border-border-default rounded text-text-primary text-xs font-mono focus:outline-none focus:border-accent-region"
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') {
                            const val = (e.target as HTMLInputElement).value;
                            if (/^#?[0-9a-f]{6}$/i.test(val)) {
                              handleColorSelect(val.startsWith('#') ? val : `#${val}`);
                            }
                          }
                        }}
                      />
                    </div>
                  </div>
                )}
              </div>
            </div>

            {/* Line 2: Start, End */}
            <div className="flex items-center gap-3">
              {/* Start position - use fetched pending bar string, or server bar string, or local calc */}
              {renderField(
                'start',
                'Start',
                displayStartBars
              )}

              <div className="w-px h-4 bg-border-default flex-shrink-0" />

              {/* End position - display only (derived from start + length) */}
              <div className="flex items-center gap-1.5">
                <span className="text-text-secondary text-xs">End:</span>
                <span className="text-text-tertiary font-mono text-xs px-1.5 py-0.5">
                  {displayEndBars}
                </span>
              </div>

              {/* Length - inline on larger screens */}
              <div className="hidden sm:flex items-center gap-3">
                <div className="w-px h-4 bg-border-default flex-shrink-0" />
                {renderField(
                  'length',
                  'Length',
                  displayLengthBars,
                  'text-accent-region-hover font-medium'
                )}
              </div>
            </div>

            {/* Line 3: Length - mobile only */}
            <div className="flex sm:hidden items-center gap-3">
              {renderField(
                'length',
                'Length',
                displayLengthBars,
                'text-accent-region-hover font-medium'
              )}
            </div>
          </>
        ) : (
          <span className="text-text-muted text-sm italic">Select a region to edit</span>
        )}
      </div>

      {/* Delete Region button - only show when a region is selected */}
      {region && (
        <button
          onClick={() => setShowDeleteModal(true)}
          className="flex items-center gap-1.5 px-3 py-2 h-10 bg-error-action/80 hover:bg-error text-text-primary text-sm font-medium rounded-lg transition-colors flex-shrink-0"
          title="Delete selected region"
        >
          <Trash2 size={16} />
          <span className="hidden sm:inline">Delete</span>
        </button>
      )}

      {/* Add Region button - long press to clone selected region */}
      {onAddRegion && (
        <button
          ref={addButtonRef}
          onPointerDown={handleAddPointerDown}
          onPointerUp={handleAddPointerUp}
          onPointerMove={handleAddPointerMove}
          onPointerLeave={handleAddPointerLeave}
          onPointerCancel={handleAddPointerLeave}
          className={`flex items-center gap-1.5 px-3 py-2 h-10 text-text-primary text-sm font-medium rounded-lg transition-colors flex-shrink-0 select-none touch-none ${
            isCloneMode
              ? 'bg-success-action hover:bg-success'
              : 'bg-accent-region hover:bg-accent-region-hover'
          }`}
          title={region ? 'Tap to add, long-press to clone selected' : 'Add new region'}
        >
          {isCloneMode ? <CopyPlus size={16} /> : <Plus size={16} />}
          <span className="hidden sm:inline">{isCloneMode ? 'Clone' : 'Add'}</span>
        </button>
      )}

      {/* Delete Region Modal */}
      <DeleteRegionModal
        isOpen={showDeleteModal}
        onClose={() => setShowDeleteModal(false)}
        region={region ?? null}
        regionId={region?.id ?? null}
      />
    </div>
  );
}
