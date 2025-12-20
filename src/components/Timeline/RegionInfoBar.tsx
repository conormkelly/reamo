/**
 * Region Info Bar Component
 * Shows name, start/end position, length, and color when a region is selected
 * Fields are tappable to edit values directly
 * Includes "Add Region" button for creating new regions
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { Plus, Trash2, CopyPlus, RotateCcw } from 'lucide-react';
import { useReaperStore } from '../../store';
import {
  hexToReaperColor,
  reaperColorToHexWithFallback,
  secondsToBeats,
  formatTime,
  formatBeats,
  formatDuration,
  parseBarBeatToSeconds,
  parseDurationToSeconds,
  parseReaperBar,
} from '../../utils';
import type { Region } from '../../core/types';
import { DeleteRegionModal } from './DeleteRegionModal';

// Default region color in REAPER (shown when color = 0)
const DEFAULT_REGION_COLOR = '#688585';

interface RegionInfoBarProps {
  className?: string;
  onAddRegion?: () => void;
}

/**
 * Format duration as editable string (just the number of bars)
 * UI-specific format for the editable duration field
 */
function formatDurationEditable(seconds: number, bpm: number, beatsPerBar: number = 4): string {
  const rawBeats = secondsToBeats(seconds, bpm);
  const totalBeats = Math.round(rawBeats * 4) / 4;
  const bars = Math.floor(totalBeats / beatsPerBar);
  const beats = Math.round(totalBeats % beatsPerBar);
  if (bars > 0 && beats > 0) {
    return `${bars}.${beats}`; // e.g., "8.2" for 8 bars 2 beats
  } else if (bars > 0) {
    return `${bars}`; // e.g., "8" for 8 bars
  } else {
    return `0.${beats}`; // e.g., "0.2" for 2 beats
  }
}

type EditingField = 'name' | 'start' | 'end' | 'length' | 'color' | null;

export function RegionInfoBar({ className = '', onAddRegion }: RegionInfoBarProps): ReactElement | null {
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const selectedRegionIndices = useReaperStore((s) => s.selectedRegionIndices);
  const regions = useReaperStore((s) => s.regions);
  const getDisplayRegions = useReaperStore((s) => s.getDisplayRegions);
  const resizeRegion = useReaperStore((s) => s.resizeRegion);
  const updateRegionMeta = useReaperStore((s) => s.updateRegionMeta);
  const createRegion = useReaperStore((s) => s.createRegion);
  const selectRegion = useReaperStore((s) => s.selectRegion);
  const nextNewRegionKey = useReaperStore((s) => s.nextNewRegionKey);
  const bpm = useReaperStore((s) => s.bpm);
  const positionBeats = useReaperStore((s) => s.positionBeats);
  const positionSeconds = useReaperStore((s) => s.positionSeconds);

  const [editingField, setEditingField] = useState<EditingField>(null);
  const [editValue, setEditValue] = useState('');
  const [showColorPicker, setShowColorPicker] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
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
  const selectedIndex = selectedRegionIndices.length === 1 ? selectedRegionIndices[0] : null;
  const region: Region | undefined = selectedIndex !== null ? displayRegions[selectedIndex] : undefined;
  // Get the pending key for the selected region (may differ from array index for new regions)
  const pendingKey = region ? (region as { _pendingKey?: number })._pendingKey ?? selectedIndex : selectedIndex;

  // Get unique colors from all regions for the picker
  const existingColors = new Set<string>();
  displayRegions.forEach((r) => {
    if (r.color) {
      existingColors.add(reaperColorToHexWithFallback(r.color, DEFAULT_REGION_COLOR));
    }
  });

  // Calculate bar offset from REAPER's actual bar numbering
  const barOffset = (() => {
    if (!bpm || !positionBeats) return 0;
    const actualBar = parseReaperBar(positionBeats);
    const rawBeats = secondsToBeats(positionSeconds, bpm);
    const totalBeats = Math.round(rawBeats * 4) / 4;
    const calculatedBar = Math.floor(totalBeats / 4) + 1;
    return actualBar - calculatedBar;
  })();

  const duration = region ? region.end - region.start : 0;
  const currentColor = region ? reaperColorToHexWithFallback(region.color, DEFAULT_REGION_COLOR) : DEFAULT_REGION_COLOR;

  const handleFieldClick = (field: EditingField) => {
    if (!region || selectedIndex === null) return;

    if (field === 'color') {
      setShowColorPicker(true);
      setEditingField('color');
      return;
    }

    if (!bpm && (field === 'start' || field === 'end' || field === 'length')) return;

    setEditingField(field);
    if (field === 'name') {
      setEditValue(region.name);
    } else if (field === 'start') {
      setEditValue(formatBeats(region.start, bpm!, barOffset));
    } else if (field === 'end') {
      setEditValue(formatBeats(region.end, bpm!, barOffset));
    } else if (field === 'length') {
      setEditValue(formatDurationEditable(duration, bpm!));
    }
  };

  // Check if region uses default color (color = 0 or undefined)
  const isDefaultColor = !region?.color || region.color === 0;

  const handleColorSelect = (hex: string) => {
    if (pendingKey === null) return;
    const reaperColor = hexToReaperColor(hex);
    updateRegionMeta(pendingKey, { color: reaperColor }, regions);
    setShowColorPicker(false);
    setEditingField(null);
  };

  const handleColorReset = () => {
    if (pendingKey === null) return;
    // Send 0 to reset to REAPER's default region color
    updateRegionMeta(pendingKey, { color: 0 }, regions);
    setShowColorPicker(false);
    setEditingField(null);
  };

  const handleConfirm = () => {
    if (!region || pendingKey === null || !editingField) {
      setEditingField(null);
      return;
    }

    if (editingField === 'name') {
      if (editValue.trim()) {
        updateRegionMeta(pendingKey, { name: editValue.trim() }, regions);
      }
    } else if (bpm) {
      let newSeconds: number | null = null;

      if (editingField === 'start') {
        newSeconds = parseBarBeatToSeconds(editValue, bpm, barOffset);
        if (newSeconds !== null && newSeconds >= 0 && newSeconds < region.end) {
          resizeRegion(pendingKey, 'start', newSeconds, regions, bpm);
        }
      } else if (editingField === 'end') {
        newSeconds = parseBarBeatToSeconds(editValue, bpm, barOffset);
        if (newSeconds !== null && newSeconds > region.start) {
          resizeRegion(pendingKey, 'end', newSeconds, regions, bpm);
        }
      } else if (editingField === 'length') {
        const newDuration = parseDurationToSeconds(editValue, bpm);
        if (newDuration !== null && newDuration > 0) {
          const newEnd = region.start + newDuration;
          resizeRegion(pendingKey, 'end', newEnd, regions, bpm);
        }
      }
    }

    setEditingField(null);
    setEditValue('');
  };

  const handleCancel = () => {
    setEditingField(null);
    setEditValue('');
    setShowColorPicker(false);
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

    // Find and select the new region in display regions
    // The new region will be at the end (highest start time), so find its index
    // We need to do this after state updates, so use setTimeout
    setTimeout(() => {
      const updatedDisplayRegions = getDisplayRegions(regions);
      const newRegionIndex = updatedDisplayRegions.findIndex(
        (r) => (r as { _pendingKey?: number })._pendingKey === newRegionKey
      );
      if (newRegionIndex !== -1) {
        selectRegion(newRegionIndex);
      }
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

  const renderField = (
    field: EditingField,
    label: string,
    value: string,
    colorClass: string = 'text-white',
    inputWidth: string = 'w-20'
  ) => {
    const isEditing = editingField === field;

    return (
      <div className="flex items-center gap-1.5">
        <span className="text-gray-400 text-xs">{label}:</span>
        {isEditing ? (
          <input
            ref={inputRef}
            type="text"
            value={editValue}
            onChange={(e) => setEditValue(e.target.value)}
            onKeyDown={handleKeyDown}
            onBlur={handleConfirm}
            className={`${inputWidth} px-1.5 py-0.5 bg-gray-700 border border-purple-400 rounded text-white font-mono text-xs focus:outline-none focus:ring-1 focus:ring-purple-400`}
          />
        ) : (
          <button
            onClick={() => handleFieldClick(field)}
            className={`${colorClass} font-mono text-xs hover:bg-gray-700 px-1.5 py-0.5 rounded transition-colors cursor-pointer truncate max-w-24`}
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
      <div className="flex flex-col gap-1 px-3 py-1.5 bg-gray-800/50 rounded-lg text-sm flex-1 min-w-0">
        {region ? (
          <>
            {/* Line 1: Name and Color */}
            <div className="flex items-center gap-3">
              {/* Name */}
              {renderField('name', 'Name', region.name, 'text-white font-medium', 'w-24')}

              <div className="w-px h-4 bg-gray-600 flex-shrink-0" />

              {/* Color */}
              <div className="flex items-center gap-1.5 relative">
                <span className="text-gray-400 text-xs">Color:</span>
                <button
                  onClick={() => handleFieldClick('color')}
                  className="w-6 h-6 rounded border-2 border-gray-600 hover:border-gray-400 transition-colors cursor-pointer"
                  style={{ backgroundColor: currentColor }}
                  title="Change color"
                />
                {showColorPicker && (
                  <div
                    ref={colorPickerRef}
                    className="absolute top-full left-0 mt-2 p-3 bg-gray-800 border border-gray-600 rounded-lg shadow-xl z-50 min-w-[200px]"
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
                              : 'border-transparent hover:border-gray-400'
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
                                : 'border-transparent hover:border-gray-400'
                            }`}
                            style={{ backgroundColor: color }}
                          />
                        ))}
                      </div>
                    </div>
                    {/* Color picker and hex input */}
                    <div className="text-xs text-gray-400 mb-1.5">Pick color</div>
                    <div className="flex gap-2 items-center">
                      <input
                        type="color"
                        value={currentColor}
                        onChange={(e) => handleColorSelect(e.target.value)}
                        className="w-8 h-8 rounded border-2 border-gray-600 cursor-pointer bg-transparent"
                        title="Pick a color"
                      />
                      <input
                        type="text"
                        placeholder="Default"
                        defaultValue={isDefaultColor ? '' : currentColor}
                        className="flex-1 px-2 py-1 bg-gray-700 border border-gray-600 rounded text-white text-xs font-mono focus:outline-none focus:border-purple-400"
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
              {/* Start position */}
              {renderField(
                'start',
                'Start',
                bpm ? formatBeats(region.start, bpm, barOffset) : formatTime(region.start)
              )}

              <div className="w-px h-4 bg-gray-600 flex-shrink-0" />

              {/* End position */}
              {renderField(
                'end',
                'End',
                bpm ? formatBeats(region.end, bpm, barOffset) : formatTime(region.end)
              )}

              {/* Length - inline on larger screens */}
              <div className="hidden sm:flex items-center gap-3">
                <div className="w-px h-4 bg-gray-600 flex-shrink-0" />
                {renderField(
                  'length',
                  'Length',
                  bpm ? formatDuration(duration, bpm) : `${duration.toFixed(2)}s`,
                  'text-purple-300 font-medium'
                )}
              </div>
            </div>

            {/* Line 3: Length - mobile only */}
            <div className="flex sm:hidden items-center gap-3">
              {renderField(
                'length',
                'Length',
                bpm ? formatDuration(duration, bpm) : `${duration.toFixed(2)}s`,
                'text-purple-300 font-medium'
              )}
            </div>
          </>
        ) : (
          <span className="text-gray-500 text-sm italic">Select a region to edit</span>
        )}
      </div>

      {/* Delete Region button - only show when a region is selected */}
      {region && pendingKey !== null && (
        <button
          onClick={() => setShowDeleteModal(true)}
          className="flex items-center gap-1.5 px-3 py-2 h-10 bg-red-600/80 hover:bg-red-500 text-white text-sm font-medium rounded-lg transition-colors flex-shrink-0"
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
          className={`flex items-center gap-1.5 px-3 py-2 h-10 text-white text-sm font-medium rounded-lg transition-colors flex-shrink-0 select-none ${
            isCloneMode
              ? 'bg-green-600 hover:bg-green-500'
              : 'bg-purple-600 hover:bg-purple-500'
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
        regionIndex={pendingKey}
      />
    </div>
  );
}
