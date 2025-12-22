/**
 * Marker Edit Modal Component
 * Modal for editing marker position, name, color, deleting, and reordering markers
 */

import { useState, useCallback, useEffect, type ReactElement } from 'react';
import { X, Trash2, ListOrdered, Move, Save, RotateCcw } from 'lucide-react';
import type { Marker } from '../../core/types';
import { formatTime, secondsToBeats, beatsToSeconds, reaperColorToHex, hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import * as commands from '../../core/CommandBuilder';

export interface MarkerEditModalProps {
  marker: Marker;
  bpm: number;
  barOffset: number;
  beatsPerBar?: number;
  denominator?: number;
  onClose: () => void;
  onMove: (markerId: number, newPositionSeconds: number) => void;
  onDelete: (markerPositionSeconds: number) => void;
  onReorderAll: () => void;
}

// Action IDs for moving markers 1-10 to edit cursor
const MARKER_MOVE_ACTIONS: Record<number, number> = {
  1: 40657,
  2: 40658,
  3: 40659,
  4: 40660,
  5: 40661,
  6: 40662,
  7: 40663,
  8: 40664,
  9: 40665,
  10: 40656,
};

/**
 * Check if a marker can be moved (only markers 1-10)
 */
export function isMarkerMoveable(markerId: number): boolean {
  return markerId >= 1 && markerId <= 10;
}

/**
 * Get the action ID for moving a specific marker
 */
export function getMarkerMoveAction(markerId: number): number | null {
  return MARKER_MOVE_ACTIONS[markerId] ?? null;
}

/**
 * Parse time string (MM:SS.ms or SS.ms) to seconds
 */
function parseTime(timeStr: string): number | null {
  const trimmed = timeStr.trim();

  // Try MM:SS.ms format
  const colonMatch = trimmed.match(/^(\d+):(\d+(?:\.\d*)?)$/);
  if (colonMatch) {
    const mins = parseInt(colonMatch[1], 10);
    const secs = parseFloat(colonMatch[2]);
    return mins * 60 + secs;
  }

  // Try just seconds
  const num = parseFloat(trimmed);
  if (!isNaN(num) && num >= 0) {
    return num;
  }

  return null;
}

/**
 * Format beats as Bar.Beat with offset for REAPER project alignment
 *
 * @param beats - Quarter-note beats (from secondsToBeats)
 * @param barOffset - Bar offset for project alignment
 * @param beatsPerBar - Numerator of time signature (e.g., 6 for 6/8)
 * @param denominator - Denominator of time signature (e.g., 8 for 6/8)
 */
function formatBars(beats: number, barOffset: number, beatsPerBar = 4, denominator = 4): string {
  // Convert quarter-note beats to denominator-note beats
  const denominatorBeats = beats * (denominator / 4);
  const calculatedBar = Math.floor(denominatorBeats / beatsPerBar) + 1;
  const actualBar = calculatedBar + barOffset;
  const beat = (denominatorBeats % beatsPerBar) + 1;
  return `${actualBar}.${beat.toFixed(2)}`;
}

/**
 * Parse bar.beat string to total quarter-note beats, accounting for REAPER bar offset
 *
 * @param barStr - Input string in "Bar.Beat" format
 * @param barOffset - Bar offset for project alignment
 * @param beatsPerBar - Numerator of time signature (e.g., 6 for 6/8)
 * @param denominator - Denominator of time signature (e.g., 8 for 6/8)
 * @returns Total quarter-note beats, or null if invalid input
 */
function parseBars(barStr: string, barOffset: number, beatsPerBar = 4, denominator = 4): number | null {
  const trimmed = barStr.trim();

  // Try Bar.Beat format (can be negative bars like -4.1)
  const match = trimmed.match(/^(-?\d+)(?:\.(\d+(?:\.\d*)?))?$/);
  if (match) {
    const displayBar = parseInt(match[1], 10);
    const beat = match[2] ? parseFloat(match[2]) - 1 : 0; // Beats are 1-indexed
    // Convert display bar to calculated bar by subtracting offset
    const calculatedBar = displayBar - barOffset - 1; // -1 because bars are 1-indexed
    if (beat >= 0) {
      // Total beats in denominator units
      const totalDenominatorBeats = calculatedBar * beatsPerBar + beat;
      // Convert denominator beats to quarter-note beats
      const quarterNoteBeats = totalDenominatorBeats * (4 / denominator);
      // Allow negative results for negative bars
      return quarterNoteBeats >= 0 ? quarterNoteBeats : 0;
    }
  }

  return null;
}

// Default marker color in REAPER (shown when color = 0)
const DEFAULT_MARKER_COLOR = '#dc2626';

// Default marker color swatches
const DEFAULT_COLORS = [
  '#dc2626', // red
  '#ea580c', // orange
  '#ca8a04', // yellow
  '#16a34a', // green
  '#0891b2', // cyan
  '#2563eb', // blue
  '#7c3aed', // purple
  '#db2777', // pink
];

export function MarkerEditModal({
  marker,
  bpm,
  barOffset,
  beatsPerBar = 4,
  denominator = 4,
  onClose,
  onMove,
  onDelete,
  onReorderAll,
}: MarkerEditModalProps): ReactElement {
  const { send } = useReaper();
  const markerScriptInstalled = useReaperStore((s) => s.markerScriptInstalled);
  const markers = useReaperStore((s) => s.markers);

  const [editMode, setEditMode] = useState<'time' | 'beats'>('time');
  const [timeValue, setTimeValue] = useState('');
  const [beatsValue, setBeatsValue] = useState('');
  const [nameValue, setNameValue] = useState('');
  const [colorValue, setColorValue] = useState<string | null>(null); // null = default (no color)
  const [error, setError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  const canMove = isMarkerMoveable(marker.id);
  const canEditNameColor = markerScriptInstalled;

  // Get existing colors from project markers
  const existingColors = [...new Set(
    markers
      .filter(m => m.color)
      .map(m => reaperColorToHexWithFallback(m.color!, '#dc2626'))
  )];

  // Check if name/color changed
  const originalName = marker.name || '';
  const originalColor = marker.color ? reaperColorToHex(marker.color) : null; // null = default
  const hasNameColorChanges = nameValue !== originalName ||
    (colorValue === null ? originalColor !== null : colorValue.toLowerCase() !== (originalColor?.toLowerCase() ?? ''));

  // Initialize values from marker
  useEffect(() => {
    setTimeValue(formatTime(marker.position, { precision: 3 }));
    const beats = secondsToBeats(marker.position, bpm);
    setBeatsValue(formatBars(beats, barOffset, beatsPerBar, denominator));
    setNameValue(marker.name || '');
    // null = default (no custom color), otherwise use hex value
    setColorValue(marker.color ? reaperColorToHex(marker.color) : null);
    setError(null);
  }, [marker, bpm, barOffset, beatsPerBar, denominator]);

  const handleMove = useCallback(() => {
    if (!canMove) return;

    let newPositionSeconds: number | null = null;

    if (editMode === 'time') {
      newPositionSeconds = parseTime(timeValue);
    } else {
      const beats = parseBars(beatsValue, barOffset, beatsPerBar, denominator);
      if (beats !== null) {
        newPositionSeconds = beatsToSeconds(beats, bpm);
      }
    }

    if (newPositionSeconds === null || newPositionSeconds < 0) {
      setError('Invalid position');
      return;
    }

    onMove(marker.id, newPositionSeconds);
    onClose();
  }, [canMove, editMode, timeValue, beatsValue, bpm, barOffset, beatsPerBar, denominator, marker.id, onMove, onClose]);

  const handleSaveNameColor = useCallback(async () => {
    if (!canEditNameColor || !hasNameColorChanges) return;

    setIsSaving(true);
    setError(null);

    try {
      // Write to EXTSTATE for the Lua script to pick up
      // colorValue null = default (send 0), otherwise convert hex to REAPER color
      const reaperColor = colorValue === null ? 0 : hexToReaperColor(colorValue);

      // Set marker_action LAST to avoid race condition (Lua polls for action)
      send(commands.setExtState('Reamo', 'marker_id', String(marker.id)));
      send(commands.setExtState('Reamo', 'marker_name', nameValue));
      send(commands.setExtState('Reamo', 'marker_color', String(reaperColor)));
      send(commands.setExtState('Reamo', 'marker_processed', ''));
      send(commands.setExtState('Reamo', 'marker_action', 'edit'));

      // Wait a bit for the script to process
      await new Promise(resolve => setTimeout(resolve, 500));

      // Refresh markers
      send(commands.markers());

      onClose();
    } catch (err) {
      setError('Failed to save changes');
    } finally {
      setIsSaving(false);
    }
  }, [canEditNameColor, hasNameColorChanges, marker.id, nameValue, colorValue, send, onClose]);

  const handleDelete = useCallback(() => {
    onDelete(marker.position);
    onClose();
  }, [marker.position, onDelete, onClose]);

  const handleReorder = useCallback(() => {
    onReorderAll();
    onClose();
  }, [onReorderAll, onClose]);

  // Close on escape
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-50"
      onClick={onClose}
    >
      <div
        className="bg-gray-800 rounded-lg shadow-xl w-80 max-w-[90vw] overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 bg-gray-900 border-b border-gray-700">
          <div className="flex items-center gap-2">
            <div
              className="w-4 h-4 rounded-full border border-gray-600"
              style={{ backgroundColor: colorValue ?? DEFAULT_MARKER_COLOR }}
            />
            <h3 className="text-white font-semibold">Marker {marker.id}</h3>
          </div>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-white transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4">
          {/* Name Input (editable if script installed, label if not) */}
          <div className="space-y-2">
            <label className="text-sm text-gray-400">Name</label>
            {canEditNameColor ? (
              <input
                type="text"
                value={nameValue}
                onChange={(e) => setNameValue(e.target.value)}
                className="w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded text-white text-sm focus:outline-none focus:border-blue-500"
                placeholder="Marker name"
              />
            ) : (
              <p className="px-3 py-2 bg-gray-900/50 border border-gray-700 rounded text-gray-400 text-sm">
                {marker.name || <span className="italic text-gray-500">No name</span>}
              </p>
            )}
          </div>

          {/* Color Picker (only if script installed) */}
          {canEditNameColor && (
            <div className="space-y-2">
              <label className="text-sm text-gray-400">Color</label>

              {/* Default + Project colors row */}
              <div className="mb-2">
                <div className="flex gap-1.5 flex-wrap items-center">
                  {/* Default (reset) color - always first */}
                  <button
                    onClick={() => setColorValue(null)}
                    className={`w-6 h-6 rounded border-2 transition-all relative ${
                      colorValue === null
                        ? 'border-white scale-110'
                        : 'border-transparent hover:border-gray-400'
                    }`}
                    style={{ backgroundColor: DEFAULT_MARKER_COLOR }}
                    title="Reset to default"
                  >
                    <RotateCcw size={10} className="absolute inset-0 m-auto text-white/80" />
                  </button>

                  {/* Existing colors from project */}
                  {existingColors.map((color) => (
                    <button
                      key={color}
                      onClick={() => setColorValue(color)}
                      className={`w-6 h-6 rounded border-2 transition-all ${
                        colorValue !== null && colorValue.toLowerCase() === color.toLowerCase()
                          ? 'border-white scale-110'
                          : 'border-transparent hover:border-gray-400'
                      }`}
                      style={{ backgroundColor: color }}
                    />
                  ))}
                </div>
              </div>

              {/* Default color swatches */}
              <div className="mb-2">
                <span className="text-xs text-gray-500 mb-1 block">Presets</span>
                <div className="flex gap-1.5 flex-wrap">
                  {DEFAULT_COLORS.map((color) => (
                    <button
                      key={color}
                      onClick={() => setColorValue(color)}
                      className={`w-6 h-6 rounded border-2 transition-all ${
                        colorValue !== null && colorValue.toLowerCase() === color.toLowerCase()
                          ? 'border-white scale-110'
                          : 'border-transparent hover:border-gray-400'
                      }`}
                      style={{ backgroundColor: color }}
                    />
                  ))}
                </div>
              </div>

              {/* Custom color picker */}
              <div className="flex gap-2 items-center">
                <input
                  type="color"
                  value={colorValue ?? DEFAULT_MARKER_COLOR}
                  onChange={(e) => setColorValue(e.target.value)}
                  className="w-8 h-8 rounded border border-gray-600 cursor-pointer bg-transparent"
                />
                <input
                  type="text"
                  value={colorValue ?? ''}
                  onChange={(e) => {
                    const val = e.target.value;
                    if (val === '') {
                      setColorValue(null);
                    } else if (/^#[0-9a-f]{0,6}$/i.test(val) || /^[0-9a-f]{0,6}$/i.test(val)) {
                      setColorValue(val.startsWith('#') ? val : `#${val}`);
                    }
                  }}
                  className="flex-1 px-2 py-1 bg-gray-900 border border-gray-600 rounded text-white text-xs font-mono focus:outline-none focus:border-blue-500"
                  placeholder="Default"
                />
              </div>
            </div>
          )}

          {/* Save Name/Color Button (only if changes and script installed) */}
          {canEditNameColor && hasNameColorChanges && (
            <button
              onClick={handleSaveNameColor}
              disabled={isSaving}
              className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-green-600 hover:bg-green-500 text-white rounded font-medium transition-colors disabled:opacity-50"
            >
              <Save size={16} />
              {isSaving ? 'Saving...' : 'Save Name & Color'}
            </button>
          )}

          {/* Script not installed message */}
          {!markerScriptInstalled && (
            <p className="text-xs text-amber-400/80">
              Install Reamo_MarkerEdit.lua to edit name and color.
            </p>
          )}

          {/* Divider */}
          <div className="border-t border-gray-700" />

          {/* Position Input */}
          <div className="space-y-2">
            <label className="text-sm text-gray-400">Position</label>

            {/* Mode Toggle */}
            <div className="flex rounded-lg overflow-hidden border border-gray-600">
              <button
                onClick={() => setEditMode('time')}
                className={`flex-1 px-3 py-1.5 text-sm font-medium transition-colors ${
                  editMode === 'time'
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                }`}
                disabled={!canMove}
              >
                Time
              </button>
              <button
                onClick={() => setEditMode('beats')}
                className={`flex-1 px-3 py-1.5 text-sm font-medium transition-colors ${
                  editMode === 'beats'
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                }`}
                disabled={!canMove}
              >
                Bar.Beat
              </button>
            </div>

            {/* Input Field */}
            {canMove ? (
              <input
                type="text"
                value={editMode === 'time' ? timeValue : beatsValue}
                onChange={(e) =>
                  editMode === 'time'
                    ? setTimeValue(e.target.value)
                    : setBeatsValue(e.target.value)
                }
                onKeyDown={(e) => {
                  if (e.key === 'Enter') handleMove();
                }}
                className="w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded text-white text-sm focus:outline-none focus:border-blue-500"
                placeholder={editMode === 'time' ? 'MM:SS.ms' : 'Bar.Beat'}
              />
            ) : (
              <div className="px-3 py-2 bg-gray-900/50 border border-gray-700 rounded text-gray-500 text-sm">
                {editMode === 'time' ? timeValue : beatsValue}
              </div>
            )}

            {/* Error or disabled message */}
            {error && <p className="text-red-400 text-xs">{error}</p>}
            {!canMove && (
              <p className="text-amber-400 text-xs">
                Only markers 1-10 can be moved. Use Reorder to renumber.
              </p>
            )}
          </div>

          {/* Move Button */}
          <button
            onClick={handleMove}
            disabled={!canMove}
            className={`w-full flex items-center justify-center gap-2 px-4 py-2 rounded font-medium transition-colors ${
              canMove
                ? 'bg-blue-600 hover:bg-blue-500 text-white'
                : 'bg-gray-700 text-gray-500 cursor-not-allowed'
            }`}
          >
            <Move size={16} />
            Move to Position
          </button>

          {/* Divider */}
          <div className="border-t border-gray-700" />

          {/* Reorder Button */}
          <button
            onClick={handleReorder}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-gray-700 hover:bg-gray-600 text-white rounded font-medium transition-colors"
          >
            <ListOrdered size={16} />
            Reorder All Markers
          </button>

          {/* Delete Button */}
          <button
            onClick={handleDelete}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-red-600/20 hover:bg-red-600/40 text-red-400 hover:text-red-300 border border-red-600/50 rounded font-medium transition-colors"
          >
            <Trash2 size={16} />
            Delete Marker
          </button>
        </div>
      </div>
    </div>
  );
}
