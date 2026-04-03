/**
 * Marker Edit Modal Component
 * Modal for editing marker name, color, position, and deleting markers
 */

import { useState, useCallback, useEffect, useRef, type ReactElement } from 'react';
import { Trash2 } from 'lucide-react';
import type { Marker } from '../../core/types';
import {
  formatTime,
  secondsToBeats,
  beatsToSeconds,
  reaperColorToHex,
  hexToReaperColor,
  formatBeatsToBarBeatTicks,
  parseBarBeatTicksToBeats,
} from '../../utils';
import { useReaper } from '../ReaperProvider';
import { marker as markerCmd } from '../../core/WebSocketCommands';
import { DEFAULT_MARKER_COLOR } from '../../constants/colors';
import { Modal, ModalFooter } from '../Modal';

export interface MarkerEditModalProps {
  marker: Marker;
  bpm: number;
  barOffset: number;
  beatsPerBar?: number;
  denominator?: number;
  onClose: () => void;
  onMove: (markerId: number, newPositionSeconds: number) => void;
  onDelete: (markerId: number) => void;
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
}: MarkerEditModalProps): ReactElement {
  const { sendCommand } = useReaper();

  const [editMode, setEditMode] = useState<'time' | 'beats'>('time');
  const [timeValue, setTimeValue] = useState('');
  const [beatsValue, setBeatsValue] = useState('');
  const [nameValue, setNameValue] = useState('');
  const [colorValue, setColorValue] = useState<string | null>(null); // null = default (no color)
  const [error, setError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const deleteTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Hold-to-reset for color swatches
  const holdTimer = useRef<number | null>(null);
  const didReset = useRef(false);
  const customColorRef = useRef<HTMLInputElement>(null);

  const HOLD_DURATION = 500;

  // Cleanup timers on unmount
  useEffect(() => {
    return () => {
      if (holdTimer.current) clearTimeout(holdTimer.current);
      if (deleteTimeoutRef.current) clearTimeout(deleteTimeoutRef.current);
    };
  }, []);

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
    if (!confirmDelete) {
      setConfirmDelete(true);
      deleteTimeoutRef.current = setTimeout(() => {
        setConfirmDelete(false);
      }, 3000);
      return;
    }
    if (deleteTimeoutRef.current) {
      clearTimeout(deleteTimeoutRef.current);
      deleteTimeoutRef.current = null;
    }
    onDelete(marker.id);
    onClose();
  }, [marker.id, onDelete, onClose, confirmDelete]);

  return (
    <Modal
      isOpen
      onClose={onClose}
      title={`Marker ${marker.id}`}
      icon={
        <div
          className="w-4 h-4 rounded-full border border-border-default"
          style={{ backgroundColor: colorValue ?? DEFAULT_MARKER_COLOR }}
        />
      }
      width="sm"
      className="max-h-[85dvh] flex flex-col"
    >
      {/* Scrollable content */}
      <div className="p-modal space-y-4 overflow-y-auto flex-1">
        {/* Name Input */}
        <div>
          <label className="block text-sm font-medium text-text-tertiary mb-1">Name</label>
          <input
            type="text"
            value={nameValue}
            onChange={(e) => setNameValue(e.target.value)}
            className="w-full px-3 py-2 bg-bg-elevated border border-border-default rounded-lg text-text-primary text-base focus:outline-none focus:border-focus-border"
            placeholder="Marker name"
          />
        </div>

        {/* Color - tap to pick, hold to reset */}
        <div className="flex items-center gap-3">
          <label className="text-sm font-medium text-text-tertiary">Color</label>
          <div
            onMouseDown={() => {
              didReset.current = false;
              holdTimer.current = window.setTimeout(() => {
                setColorValue(null);
                didReset.current = true;
              }, HOLD_DURATION);
            }}
            onMouseUp={() => {
              if (holdTimer.current) { clearTimeout(holdTimer.current); holdTimer.current = null; }
              if (!didReset.current) customColorRef.current?.click();
            }}
            onMouseLeave={() => {
              if (holdTimer.current) { clearTimeout(holdTimer.current); holdTimer.current = null; }
            }}
            onTouchStart={() => {
              didReset.current = false;
              holdTimer.current = window.setTimeout(() => {
                setColorValue(null);
                didReset.current = true;
              }, HOLD_DURATION);
            }}
            onTouchEnd={() => {
              if (holdTimer.current) { clearTimeout(holdTimer.current); holdTimer.current = null; }
              if (!didReset.current) customColorRef.current?.click();
            }}
            className="relative w-10 h-10 rounded-lg border-2 border-border-default cursor-pointer hover:border-text-secondary transition-colors touch-none"
            style={{ backgroundColor: colorValue ?? DEFAULT_MARKER_COLOR }}
            title={colorValue === null ? 'Tap to pick color' : `${colorValue} (hold to reset)`}
          >
            {/* Non-default indicator dot */}
            {colorValue !== null && (
              <div className="absolute -top-1 -right-1 w-3 h-3 bg-primary-hover rounded-full border border-bg-surface" />
            )}
            <input
              ref={customColorRef}
              type="color"
              value={colorValue ?? DEFAULT_MARKER_COLOR}
              onChange={(e) => setColorValue(e.target.value)}
              className="absolute inset-0 opacity-0 cursor-pointer"
              tabIndex={-1}
            />
          </div>
        </div>

        {/* Position - compact single row */}
        <div>
          <label className="block text-sm font-medium text-text-tertiary mb-1">Position</label>
          <div className="flex gap-2 items-center">
            {/* Compact mode toggle */}
            <div className="flex rounded-lg overflow-hidden border border-border-default flex-shrink-0">
              <button
                onClick={() => setEditMode('time')}
                className={`px-2.5 py-1.5 text-xs font-medium transition-colors ${
                  editMode === 'time'
                    ? 'bg-primary text-text-on-primary'
                    : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                }`}
              >
                Time
              </button>
              <button
                onClick={() => setEditMode('beats')}
                className={`px-2.5 py-1.5 text-xs font-medium transition-colors ${
                  editMode === 'beats'
                    ? 'bg-primary text-text-on-primary'
                    : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                }`}
              >
                Bar
              </button>
            </div>

            {/* Position input */}
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
              className="flex-1 min-w-0 px-3 py-1.5 bg-bg-elevated border border-border-default rounded-lg text-text-primary text-base focus:outline-none focus:border-focus-border"
              placeholder={editMode === 'time' ? 'MM:SS.ms' : 'Bar.Beat'}
            />

            {/* Compact Move button */}
            <button
              onClick={handleMove}
              className="px-3 py-1.5 rounded-lg font-medium text-sm transition-colors bg-primary hover:bg-primary-hover text-text-on-primary flex-shrink-0"
            >
              Move
            </button>
          </div>
          {error && <p className="text-error-text text-xs mt-1">{error}</p>}
        </div>
      </div>

      <ModalFooter
        onCancel={onClose}
        onConfirm={handleSaveNameColor}
        confirmText="Save"
        confirmVariant="success"
        confirmDisabled={!hasNameColorChanges}
        confirmLoading={isSaving}
        leftContent={
          <button
            onClick={handleDelete}
            className={`px-3 py-2 text-sm font-medium rounded-lg transition-colors flex items-center gap-1.5 ${
              confirmDelete
                ? 'bg-error-bg text-error-text'
                : 'hover:bg-bg-elevated text-text-secondary hover:text-error-text'
            }`}
            title={confirmDelete ? 'Tap again to confirm' : 'Delete marker'}
          >
            <Trash2 size={14} />
            {confirmDelete ? 'Confirm' : 'Delete'}
          </button>
        }
      />
    </Modal>
  );
}
