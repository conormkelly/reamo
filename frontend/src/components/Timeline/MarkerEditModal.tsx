/**
 * Marker Edit Modal Component
 * Modal for editing marker position, name, color, deleting, and reordering markers
 */

import { useState, useCallback, useEffect, type ReactElement } from 'react';
import { X, Trash2, ListOrdered, Move, Save, RotateCcw } from 'lucide-react';
import type { Marker } from '../../core/types';
import {
  formatTime,
  secondsToBeats,
  beatsToSeconds,
  reaperColorToHex,
  hexToReaperColor,
  reaperColorToHexWithFallback,
  formatBeatsToBarBeatTicks,
  parseBarBeatTicksToBeats,
} from '../../utils';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { marker as markerCmd } from '../../core/WebSocketCommands';
import { DEFAULT_MARKER_COLOR, MARKER_COLORS } from '../../constants/colors';

export interface MarkerEditModalProps {
  marker: Marker;
  bpm: number;
  barOffset: number;
  beatsPerBar?: number;
  denominator?: number;
  onClose: () => void;
  onMove: (markerId: number, newPositionSeconds: number) => void;
  onDelete: (markerId: number) => void;
  onReorderAll: () => void;
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
  const { sendCommand } = useReaper();
  const markers = useReaperStore((s) => s.markers);

  const [editMode, setEditMode] = useState<'time' | 'beats'>('time');
  const [timeValue, setTimeValue] = useState('');
  const [beatsValue, setBeatsValue] = useState('');
  const [nameValue, setNameValue] = useState('');
  const [colorValue, setColorValue] = useState<string | null>(null); // null = default (no color)
  const [error, setError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  // Get existing colors from project markers
  const existingColors = [...new Set(
    markers
      .filter(m => m.color)
      .map(m => reaperColorToHexWithFallback(m.color!, DEFAULT_MARKER_COLOR))
  )];

  // Check if name/color changed
  const originalName = marker.name || '';
  const originalColor = marker.color ? reaperColorToHex(marker.color) : null; // null = default
  const hasNameColorChanges = nameValue !== originalName ||
    (colorValue === null ? originalColor !== null : colorValue.toLowerCase() !== (originalColor?.toLowerCase() ?? ''));

  // Initialize values from marker
  useEffect(() => {
    setTimeValue(formatTime(marker.position, { precision: 3 }));
    const quarterNoteBeats = secondsToBeats(marker.position, bpm);
    // Convert quarter-note beats to denominator beats for display
    const denominatorBeats = quarterNoteBeats * (denominator / 4);
    setBeatsValue(formatBeatsToBarBeatTicks(denominatorBeats, beatsPerBar, true, barOffset));
    setNameValue(marker.name || '');
    // null = default (no custom color), otherwise use hex value
    setColorValue(marker.color ? reaperColorToHex(marker.color) : null);
    setError(null);
  }, [marker, bpm, barOffset, beatsPerBar, denominator]);

  const handleMove = useCallback(() => {
    let newPositionSeconds: number | null = null;

    if (editMode === 'time') {
      newPositionSeconds = parseTime(timeValue);
    } else {
      // Parse bar.beat string and convert to quarter-note beats
      const denominatorBeats = parseBarBeatTicksToBeats(beatsValue, beatsPerBar, barOffset);
      if (denominatorBeats !== null) {
        const quarterNoteBeats = denominatorBeats * (4 / denominator);
        const beats = quarterNoteBeats >= 0 ? quarterNoteBeats : 0;
        newPositionSeconds = beatsToSeconds(beats, bpm);
      }
    }

    if (newPositionSeconds === null || newPositionSeconds < 0) {
      setError('Invalid position');
      return;
    }

    onMove(marker.id, newPositionSeconds);
    onClose();
  }, [editMode, timeValue, beatsValue, bpm, barOffset, beatsPerBar, denominator, marker.id, onMove, onClose]);

  const handleSaveNameColor = useCallback(() => {
    if (!hasNameColorChanges) return;

    setIsSaving(true);
    setError(null);

    // colorValue null = default (send 0), otherwise convert hex to REAPER color
    const reaperColor = colorValue === null ? 0 : hexToReaperColor(colorValue);

    // Use native marker/update command
    sendCommand(markerCmd.update(marker.id, { name: nameValue, color: reaperColor }));

    // WebSocket will push updated markers, close immediately
    setIsSaving(false);
    onClose();
  }, [hasNameColorChanges, marker.id, nameValue, colorValue, sendCommand, onClose]);

  const handleDelete = useCallback(() => {
    onDelete(marker.id);
    onClose();
  }, [marker.id, onDelete, onClose]);

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
        className="bg-bg-surface rounded-lg shadow-xl w-80 max-w-[90vw] overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 bg-bg-deep border-b border-border-subtle">
          <div className="flex items-center gap-2">
            <div
              className="w-4 h-4 rounded-full border border-border-default"
              style={{ backgroundColor: colorValue ?? DEFAULT_MARKER_COLOR }}
            />
            <h3 className="text-text-primary font-semibold">Marker {marker.id}</h3>
          </div>
          <button
            onClick={onClose}
            className="text-text-secondary hover:text-text-primary transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4">
          {/* Name Input */}
          <div className="space-y-2">
            <label className="text-sm text-text-secondary">Name</label>
            <input
              type="text"
              value={nameValue}
              onChange={(e) => setNameValue(e.target.value)}
              className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded text-text-primary text-sm focus:outline-none focus:border-focus-border"
              placeholder="Marker name"
            />
          </div>

          {/* Color Picker */}
          <div className="space-y-2">
              <label className="text-sm text-text-secondary">Color</label>

              {/* Default + Project colors row */}
              <div className="mb-2">
                <div className="flex gap-1.5 flex-wrap items-center">
                  {/* Default (reset) color - always first */}
                  <button
                    onClick={() => setColorValue(null)}
                    className={`w-6 h-6 rounded border-2 transition-all relative ${
                      colorValue === null
                        ? 'border-white scale-110'
                        : 'border-transparent hover:border-text-secondary'
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
                          : 'border-transparent hover:border-text-secondary'
                      }`}
                      style={{ backgroundColor: color }}
                    />
                  ))}
                </div>
              </div>

              {/* Default color swatches */}
              <div className="mb-2">
                <span className="text-xs text-text-muted mb-1 block">Presets</span>
                <div className="flex gap-1.5 flex-wrap">
                  {MARKER_COLORS.map((color) => (
                    <button
                      key={color}
                      onClick={() => setColorValue(color)}
                      className={`w-6 h-6 rounded border-2 transition-all ${
                        colorValue !== null && colorValue.toLowerCase() === color.toLowerCase()
                          ? 'border-white scale-110'
                          : 'border-transparent hover:border-text-secondary'
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
                  className="w-8 h-8 rounded border border-border-default cursor-pointer bg-transparent"
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
                  className="flex-1 px-2 py-1 bg-bg-deep border border-border-default rounded text-text-primary text-xs font-mono focus:outline-none focus:border-focus-border"
                  placeholder="Default"
                />
              </div>
          </div>

          {/* Save Name/Color Button (only if changes) */}
          {hasNameColorChanges && (
            <button
              onClick={handleSaveNameColor}
              disabled={isSaving}
              className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-success-action hover:bg-success text-text-on-success rounded font-medium transition-colors disabled:opacity-50"
            >
              <Save size={16} />
              {isSaving ? 'Saving...' : 'Save Name & Color'}
            </button>
          )}

          {/* Divider */}
          <div className="border-t border-border-subtle" />

          {/* Position Input */}
          <div className="space-y-2">
            <label className="text-sm text-text-secondary">Position</label>

            {/* Mode Toggle */}
            <div className="flex rounded-lg overflow-hidden border border-border-default">
              <button
                onClick={() => setEditMode('time')}
                className={`flex-1 px-3 py-1.5 text-sm font-medium transition-colors ${
                  editMode === 'time'
                    ? 'bg-primary text-text-on-primary'
                    : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                }`}
              >
                Time
              </button>
              <button
                onClick={() => setEditMode('beats')}
                className={`flex-1 px-3 py-1.5 text-sm font-medium transition-colors ${
                  editMode === 'beats'
                    ? 'bg-primary text-text-on-primary'
                    : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                }`}
              >
                Bar.Beat
              </button>
            </div>

            {/* Input Field */}
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
              className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded text-text-primary text-sm focus:outline-none focus:border-focus-border"
              placeholder={editMode === 'time' ? 'MM:SS.ms' : 'Bar.Beat'}
            />

            {/* Error message */}
            {error && <p className="text-error-text text-xs">{error}</p>}
          </div>

          {/* Move Button */}
          <button
            onClick={handleMove}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 rounded font-medium transition-colors bg-primary hover:bg-primary-hover text-text-on-primary"
          >
            <Move size={16} />
            Move to Position
          </button>

          {/* Divider */}
          <div className="border-t border-border-subtle" />

          {/* Reorder Button */}
          <button
            onClick={handleReorder}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-bg-elevated hover:bg-bg-hover text-text-primary rounded font-medium transition-colors"
          >
            <ListOrdered size={16} />
            Reorder All Markers
          </button>

          {/* Delete Button */}
          <button
            onClick={handleDelete}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-delete-bg hover:bg-delete-bg-hover text-delete-text hover:text-delete-text-hover border border-delete-border rounded font-medium transition-colors"
          >
            <Trash2 size={16} />
            Delete Marker
          </button>
        </div>
      </div>
    </div>
  );
}
