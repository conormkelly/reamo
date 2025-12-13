/**
 * Marker Edit Modal Component
 * Modal for editing marker position, deleting, and reordering markers
 */

import { useState, useCallback, useEffect, type ReactElement } from 'react';
import { X, Trash2, ListOrdered, Move } from 'lucide-react';
import type { Marker } from '../../core/types';

export interface MarkerEditModalProps {
  marker: Marker;
  bpm: number;
  barOffset: number;
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
 * Format seconds as MM:SS.ms
 */
function formatTime(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins}:${secs.toFixed(3).padStart(6, '0')}`;
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
 */
function formatBars(beats: number, barOffset: number, beatsPerBar: number = 4): string {
  const calculatedBar = Math.floor(beats / beatsPerBar) + 1;
  const actualBar = calculatedBar + barOffset;
  const beat = (beats % beatsPerBar) + 1;
  return `${actualBar}.${beat.toFixed(2)}`;
}

/**
 * Parse bar.beat string to total beats, accounting for REAPER bar offset
 */
function parseBars(barStr: string, barOffset: number, beatsPerBar: number = 4): number | null {
  const trimmed = barStr.trim();

  // Try Bar.Beat format (can be negative bars like -4.1)
  const match = trimmed.match(/^(-?\d+)(?:\.(\d+(?:\.\d*)?))?$/);
  if (match) {
    const displayBar = parseInt(match[1], 10);
    const beat = match[2] ? parseFloat(match[2]) - 1 : 0; // Beats are 1-indexed
    // Convert display bar to calculated bar by subtracting offset
    const calculatedBar = displayBar - barOffset - 1; // -1 because bars are 1-indexed
    if (beat >= 0) {
      const totalBeats = calculatedBar * beatsPerBar + beat;
      // Allow negative results for negative bars
      return totalBeats >= 0 ? totalBeats : 0;
    }
  }

  return null;
}

/**
 * Convert seconds to beats
 */
function secondsToBeats(seconds: number, bpm: number): number {
  return seconds * (bpm / 60);
}

/**
 * Convert beats to seconds
 */
function beatsToSeconds(beats: number, bpm: number): number {
  return beats * (60 / bpm);
}

export function MarkerEditModal({
  marker,
  bpm,
  barOffset,
  onClose,
  onMove,
  onDelete,
  onReorderAll,
}: MarkerEditModalProps): ReactElement {
  const [editMode, setEditMode] = useState<'time' | 'beats'>('time');
  const [timeValue, setTimeValue] = useState('');
  const [beatsValue, setBeatsValue] = useState('');
  const [error, setError] = useState<string | null>(null);

  const canMove = isMarkerMoveable(marker.id);

  // Initialize values from marker
  useEffect(() => {
    setTimeValue(formatTime(marker.position));
    const beats = secondsToBeats(marker.position, bpm);
    setBeatsValue(formatBars(beats, barOffset));
    setError(null);
  }, [marker, bpm, barOffset]);

  const handleMove = useCallback(() => {
    if (!canMove) return;

    let newPositionSeconds: number | null = null;

    if (editMode === 'time') {
      newPositionSeconds = parseTime(timeValue);
    } else {
      const beats = parseBars(beatsValue, barOffset);
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
  }, [canMove, editMode, timeValue, beatsValue, bpm, barOffset, marker.id, onMove, onClose]);

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
          <h3 className="text-white font-semibold">Marker {marker.id}</h3>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-white transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4">
          {/* Marker name if present */}
          {marker.name && (
            <p className="text-gray-300 text-sm">{marker.name}</p>
          )}

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
