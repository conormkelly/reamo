/**
 * Marker Info Bar Component
 * Shows marker info in Navigate mode: ID, name, color, timestamp
 * Supports inline editing when Lua script is installed
 * Auto-advances to show the most recently passed marker during playback
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { RotateCcw } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useCurrentMarker } from '../../hooks/useCurrentMarker';
import * as commands from '../../core/CommandBuilder';
import {
  reaperColorToHex,
  hexToReaperColor,
  formatTime,
  formatBeats,
  parseReaperBar,
  secondsToBeats,
} from '../../utils';

// Default marker color in REAPER (shown when color = 0)
const DEFAULT_MARKER_COLOR = '#dc2626';

// Preset colors for quick selection
const PRESET_COLORS = [
  '#dc2626', // red
  '#ea580c', // orange
  '#eab308', // yellow
  '#22c55e', // green
  '#06b6d4', // cyan
  '#3b82f6', // blue
  '#8b5cf6', // purple
  '#ec4899', // pink
];

interface MarkerInfoBarProps {
  className?: string;
}

export function MarkerInfoBar({ className = '' }: MarkerInfoBarProps): ReactElement | null {
  const { send } = useReaper();
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const markerScriptInstalled = useReaperStore((s) => s.markerScriptInstalled);
  const markers = useReaperStore((s) => s.markers);
  const bpm = useReaperStore((s) => s.bpm);
  const positionBeats = useReaperStore((s) => s.positionBeats);
  const positionSeconds = useReaperStore((s) => s.positionSeconds);
  const timeSignature = useReaperStore((s) => s.timeSignature);

  // Parse time signature numerator (beats per bar) and denominator
  const { beatsPerBar, denominator } = (() => {
    const [num, denom] = timeSignature.split('/').map(Number);
    return { beatsPerBar: num || 4, denominator: denom || 4 };
  })();

  const { currentMarker, setLocked } = useCurrentMarker();

  const [isEditingName, setIsEditingName] = useState(false);
  const [nameValue, setNameValue] = useState('');
  const [showColorPicker, setShowColorPicker] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  const nameInputRef = useRef<HTMLInputElement>(null);
  const colorPickerRef = useRef<HTMLDivElement>(null);
  const saveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Only show in navigate mode
  if (timelineMode !== 'navigate') {
    return null;
  }

  // Calculate bar offset from REAPER's actual bar numbering
  const barOffset = (() => {
    if (!bpm || !positionBeats) return 0;
    const actualBar = parseReaperBar(positionBeats);
    // BPM is in quarter notes, convert to denominator beats
    const quarterNoteBeats = secondsToBeats(positionSeconds, bpm);
    const denominatorBeats = quarterNoteBeats * (denominator / 4);
    const totalBeats = Math.round(denominatorBeats * 4) / 4;
    const calculatedBar = Math.floor(totalBeats / beatsPerBar) + 1;
    return actualBar - calculatedBar;
  })();

  // Get colors from existing markers for picker
  const existingColors = new Set<string>();
  markers.forEach((m) => {
    if (m.color) {
      const hex = reaperColorToHex(m.color);
      if (hex) existingColors.add(hex);
    }
  });

  // Check if marker uses default color (color = 0 or undefined)
  const isDefaultColor = !currentMarker?.color || currentMarker.color === 0;
  const currentColor = isDefaultColor
    ? DEFAULT_MARKER_COLOR
    : reaperColorToHex(currentMarker.color!) ?? DEFAULT_MARKER_COLOR;

  // Focus name input when editing starts
  useEffect(() => {
    if (isEditingName && nameInputRef.current) {
      nameInputRef.current.focus();
      nameInputRef.current.select();
    }
  }, [isEditingName]);

  // Close color picker on outside click
  useEffect(() => {
    if (!showColorPicker) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (colorPickerRef.current && !colorPickerRef.current.contains(e.target as Node)) {
        setShowColorPicker(false);
        setLocked(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showColorPicker, setLocked]);

  // Lock auto-advance when editing
  useEffect(() => {
    if (isEditingName || showColorPicker) {
      setLocked(true);
    }
  }, [isEditingName, showColorPicker, setLocked]);

  // Debounced save function
  const saveMarkerEdit = useCallback(
    async (name: string, color: number) => {
      if (!currentMarker) return;

      setIsSaving(true);

      // Write to EXTSTATE for Lua script to process
      // Set marker_action LAST to avoid race condition (Lua polls for action)
      send(commands.setExtState('Reamo', 'marker_id', String(currentMarker.id)));
      send(commands.setExtState('Reamo', 'marker_name', name));
      send(commands.setExtState('Reamo', 'marker_color', String(color)));
      send(commands.setExtState('Reamo', 'marker_processed', ''));
      send(commands.setExtState('Reamo', 'marker_action', 'edit'));

      // Wait for script to process
      await new Promise((resolve) => setTimeout(resolve, 300));

      // Refresh markers
      send(commands.markers());

      setIsSaving(false);
    },
    [currentMarker, send]
  );

  const handleNameClick = () => {
    if (!markerScriptInstalled || !currentMarker) return;
    setNameValue(currentMarker.name);
    setIsEditingName(true);
  };

  const handleNameConfirm = () => {
    if (!currentMarker) {
      setIsEditingName(false);
      return;
    }

    const trimmedName = nameValue.trim();
    if (trimmedName && trimmedName !== currentMarker.name) {
      // Debounced save
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
      saveTimeoutRef.current = setTimeout(() => {
        saveMarkerEdit(trimmedName, currentMarker.color ?? 0);
      }, 300);
    }

    setIsEditingName(false);
    setLocked(false);
  };

  const handleNameCancel = () => {
    setIsEditingName(false);
    setLocked(false);
  };

  const handleNameKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleNameConfirm();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      handleNameCancel();
    }
  };

  const handleColorClick = () => {
    if (!markerScriptInstalled || !currentMarker) return;
    setShowColorPicker(true);
  };

  const handleColorSelect = (hex: string) => {
    if (!currentMarker) return;
    const reaperColor = hexToReaperColor(hex);
    saveMarkerEdit(currentMarker.name, reaperColor);
    setShowColorPicker(false);
    setLocked(false);
  };

  const handleColorReset = () => {
    if (!currentMarker) return;
    // Send 0 to reset to REAPER's default marker color
    saveMarkerEdit(currentMarker.name, 0);
    setShowColorPicker(false);
    setLocked(false);
  };

  // Format position as beats or time
  const formatPosition = (seconds: number): string => {
    if (bpm) {
      return formatBeats(seconds, bpm, barOffset, beatsPerBar, denominator);
    }
    return formatTime(seconds);
  };

  return (
    <div className={`flex items-center gap-2 min-w-0 ${className}`}>
      <div className="flex flex-col gap-1 px-3 py-1.5 bg-gray-800/50 rounded-lg text-sm flex-1 min-w-0">
        {currentMarker ? (
          <>
            {/* Line 1: Marker ID and Name */}
            <div className="flex items-center gap-3 min-w-0">
              {/* Marker ID */}
              <div className="flex items-center gap-1.5">
                <span className="text-gray-400 text-xs">Marker:</span>
                <span className="text-white font-mono text-xs font-bold">{currentMarker.id}</span>
              </div>

              <div className="w-px h-4 bg-gray-600 flex-shrink-0" />

              {/* Name (editable if script installed) */}
              <div className="flex items-center gap-1.5 flex-1 min-w-0">
                <span className="text-gray-400 text-xs flex-shrink-0">Name:</span>
                {isEditingName ? (
                  <input
                    ref={nameInputRef}
                    type="text"
                    value={nameValue}
                    onChange={(e) => setNameValue(e.target.value)}
                    onKeyDown={handleNameKeyDown}
                    onBlur={handleNameConfirm}
                    className="flex-1 min-w-0 px-1.5 py-0.5 bg-gray-700 border border-blue-400 rounded text-white font-mono text-xs focus:outline-none focus:ring-1 focus:ring-blue-400"
                  />
                ) : (
                  <button
                    onClick={handleNameClick}
                    disabled={!markerScriptInstalled}
                    className={`text-white font-mono text-xs px-1.5 py-0.5 rounded transition-colors truncate min-w-0 ${
                      markerScriptInstalled
                        ? 'hover:bg-gray-700 cursor-pointer'
                        : 'cursor-default'
                    }`}
                    title={
                      markerScriptInstalled
                        ? 'Click to edit name'
                        : 'Install Reamo_MarkerEdit.lua to edit'
                    }
                  >
                    {currentMarker.name || '(unnamed)'}
                  </button>
                )}
              </div>

              {/* Saving indicator */}
              {isSaving && (
                <span className="text-gray-500 text-xs italic ml-auto">Saving...</span>
              )}
            </div>

            {/* Line 2: Color and Position */}
            <div className="flex items-center gap-3">
              {/* Color indicator */}
              <div className="flex items-center gap-1.5 relative">
                <span className="text-gray-400 text-xs">Color:</span>
                <button
                  onClick={handleColorClick}
                  disabled={!markerScriptInstalled}
                  className={`w-6 h-6 rounded border-2 transition-colors ${
                    markerScriptInstalled
                      ? 'border-gray-600 hover:border-gray-400 cursor-pointer'
                      : 'border-gray-700 cursor-default'
                  }`}
                  style={{ backgroundColor: currentColor }}
                  title={
                    markerScriptInstalled
                      ? 'Click to change color'
                      : 'Install Reamo_MarkerEdit.lua to edit'
                  }
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
                          style={{ backgroundColor: DEFAULT_MARKER_COLOR }}
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

                    {/* Preset colors */}
                    <div className="mb-3">
                      <div className="text-xs text-gray-400 mb-1.5">Presets</div>
                      <div className="flex gap-2 flex-wrap">
                        {PRESET_COLORS.map((color) => (
                          <button
                            key={color}
                            onClick={() => handleColorSelect(color)}
                            className={`w-6 h-6 rounded border-2 transition-all ${
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
                    <div className="text-xs text-gray-400 mb-1.5">Custom</div>
                    <div className="flex gap-2 items-center">
                      <input
                        type="color"
                        value={currentColor}
                        onChange={(e) => handleColorSelect(e.target.value)}
                        className="w-8 h-8 rounded border-2 border-gray-600 cursor-pointer bg-transparent"
                      />
                      <input
                        type="text"
                        placeholder="Default"
                        defaultValue={isDefaultColor ? '' : currentColor}
                        className="flex-1 px-2 py-1 bg-gray-700 border border-gray-600 rounded text-white text-xs font-mono focus:outline-none focus:border-blue-400"
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

              <div className="w-px h-4 bg-gray-600 flex-shrink-0" />

              {/* Position */}
              <div className="flex items-center gap-1.5">
                <span className="text-gray-400 text-xs">At:</span>
                <span className="text-blue-300 font-mono text-xs">
                  {formatPosition(currentMarker.position)}
                </span>
              </div>
            </div>
          </>
        ) : (
          <span className="text-gray-500 text-sm italic">
            No marker selected
          </span>
        )}
      </div>
    </div>
  );
}
