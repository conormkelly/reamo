/**
 * Make Selection Modal Component
 * Modal dialog for precisely setting time selection using bar.beat.tick notation
 */

import { useState, useEffect, useRef, type ReactElement } from 'react';
import { X } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { useTimeSignature, useBarOffset } from '../../hooks';
import {
  beatsToSeconds,
  secondsToBeats,
  parseBarBeatTicksToBeats,
  formatBeatsToBarBeatTicks,
} from '../../utils';
import { timeSelection as timeSelCmd } from '../../core/WebSocketCommands';

interface MakeSelectionModalProps {
  isOpen: boolean;
  onClose: () => void;
}

/**
 * Format seconds to time string (MM:SS.mmm or HH:MM:SS.mmm)
 */
function formatTimeLocal(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;

  if (hours > 0) {
    return `${hours}:${mins.toString().padStart(2, '0')}:${secs.toFixed(3).padStart(6, '0')}`;
  }
  return `${mins}:${secs.toFixed(3).padStart(6, '0')}`;
}

/**
 * Parse time string to seconds
 */
function parseTimeLocal(input: string): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;

  // Try parsing as seconds first (e.g., "120.5")
  const asSeconds = parseFloat(trimmed);
  if (!isNaN(asSeconds) && !trimmed.includes(':')) {
    return asSeconds;
  }

  // Parse as MM:SS or HH:MM:SS
  const parts = trimmed.split(':');
  if (parts.length === 2) {
    const mins = parseInt(parts[0], 10);
    const secs = parseFloat(parts[1]);
    if (!isNaN(mins) && !isNaN(secs)) {
      return mins * 60 + secs;
    }
  } else if (parts.length === 3) {
    const hours = parseInt(parts[0], 10);
    const mins = parseInt(parts[1], 10);
    const secs = parseFloat(parts[2]);
    if (!isNaN(hours) && !isNaN(mins) && !isNaN(secs)) {
      return hours * 3600 + mins * 60 + secs;
    }
  }

  return null;
}

export function MakeSelectionModal({ isOpen, onClose }: MakeSelectionModalProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const bpm = useReaperStore((s) => s.bpm);
  const timeSelection = useReaperStore((s) => s.timeSelection);
  const setTimeSelection = useReaperStore((s) => s.setTimeSelection);

  const { beatsPerBar, denominator } = useTimeSignature();
  const barOffset = useBarOffset();

  const [mode, setMode] = useState<'beats' | 'time'>('beats');
  const [startValue, setStartValue] = useState('1.1');
  const [endValue, setEndValue] = useState('2.1');
  const [error, setError] = useState<string | null>(null);

  const modalRef = useRef<HTMLDivElement>(null);
  const wasOpenRef = useRef(false);
  const prevModeRef = useRef<'beats' | 'time'>(mode);
  const capturedBarOffsetRef = useRef<number>(0); // Captured on modal open to prevent drift during playback

  // Reset form when modal opens
  useEffect(() => {
    if (isOpen && !wasOpenRef.current) {
      setError(null);
      // Capture barOffset when modal opens - use this fixed value for all conversions
      capturedBarOffsetRef.current = barOffset;
      const effectiveBpm = bpm && bpm > 0 ? bpm : 120;

      // Pre-populate with current time selection if exists
      if (timeSelection) {
        const startSeconds = beatsToSeconds(timeSelection.startBeats, effectiveBpm);
        const endSeconds = beatsToSeconds(timeSelection.endBeats, effectiveBpm);

        if (mode === 'beats') {
          // Convert quarter-note beats to denominator beats, barOffset handled by utility
          const startDenomBeats = timeSelection.startBeats * (denominator / 4);
          const endDenomBeats = timeSelection.endBeats * (denominator / 4);
          setStartValue(formatBeatsToBarBeatTicks(startDenomBeats, beatsPerBar, true, capturedBarOffsetRef.current));
          setEndValue(formatBeatsToBarBeatTicks(endDenomBeats, beatsPerBar, true, capturedBarOffsetRef.current));
        } else {
          setStartValue(formatTimeLocal(startSeconds));
          setEndValue(formatTimeLocal(endSeconds));
        }
      } else {
        // Default to bar 1 to bar 2
        if (mode === 'beats') {
          setStartValue('1.1');
          setEndValue('2.1');
        } else {
          setStartValue('0:00.000');
          setEndValue(formatTimeLocal(beatsToSeconds(4, effectiveBpm)));
        }
      }
    }
    wasOpenRef.current = isOpen;
  }, [isOpen, bpm, barOffset, timeSelection, mode, beatsPerBar, denominator]);

  // Convert values when mode changes while modal is open
  useEffect(() => {
    if (!isOpen) return;
    if (mode === prevModeRef.current) return;

    const prevMode = prevModeRef.current;
    prevModeRef.current = mode;

    const effectiveBpm = bpm && bpm > 0 ? bpm : 120;
    // Use captured barOffset to ensure consistent conversions
    const offset = capturedBarOffsetRef.current;

    // Convert start value
    let startSeconds: number | null = null;
    let endSeconds: number | null = null;

    if (prevMode === 'beats') {
      // Parse from bar.beat format - barOffset handled by utility
      const startDenomBeats = parseBarBeatTicksToBeats(startValue, beatsPerBar, offset);
      const endDenomBeats = parseBarBeatTicksToBeats(endValue, beatsPerBar, offset);

      if (startDenomBeats !== null) {
        // Convert denominator beats to quarter notes
        const quarterNoteBeats = startDenomBeats * (4 / denominator);
        startSeconds = beatsToSeconds(quarterNoteBeats, effectiveBpm);
      }
      if (endDenomBeats !== null) {
        const quarterNoteBeats = endDenomBeats * (4 / denominator);
        endSeconds = beatsToSeconds(quarterNoteBeats, effectiveBpm);
      }
    } else {
      // Parse from time format
      startSeconds = parseTimeLocal(startValue);
      endSeconds = parseTimeLocal(endValue);
    }

    // Format to new mode
    if (mode === 'time') {
      // Convert to time format
      if (startSeconds !== null) {
        setStartValue(formatTimeLocal(startSeconds));
      }
      if (endSeconds !== null) {
        setEndValue(formatTimeLocal(endSeconds));
      }
    } else {
      // Convert to bar.beat format - barOffset handled by utility
      if (startSeconds !== null) {
        // Convert seconds to quarter notes, then to denominator beats
        const quarterNoteBeats = secondsToBeats(startSeconds, effectiveBpm);
        const denomBeats = quarterNoteBeats * (denominator / 4);
        setStartValue(formatBeatsToBarBeatTicks(denomBeats, beatsPerBar, true, offset));
      }
      if (endSeconds !== null) {
        const quarterNoteBeats = secondsToBeats(endSeconds, effectiveBpm);
        const denomBeats = quarterNoteBeats * (denominator / 4);
        setEndValue(formatBeatsToBarBeatTicks(denomBeats, beatsPerBar, true, offset));
      }
    }

    setError(null);
  }, [mode, isOpen, bpm, startValue, endValue, beatsPerBar, denominator]);

  // Close on escape key
  useEffect(() => {
    if (!isOpen) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [isOpen, onClose]);

  // Close when clicking outside
  const handleBackdropClick = (e: React.MouseEvent) => {
    if (e.target === e.currentTarget) {
      onClose();
    }
  };

  const handleApply = () => {
    const effectiveBpm = bpm && bpm > 0 ? bpm : 120;
    // Use captured barOffset for consistency
    const offset = capturedBarOffsetRef.current;

    let startSeconds: number;
    let endSeconds: number;

    if (mode === 'beats') {
      // Parse to get denominator beats - barOffset handled by utility
      const startDenomBeats = parseBarBeatTicksToBeats(startValue, beatsPerBar, offset);
      const endDenomBeats = parseBarBeatTicksToBeats(endValue, beatsPerBar, offset);

      if (startDenomBeats === null) {
        setError('Start must be a valid position (e.g., 1.1 or 5.2.50)');
        return;
      }
      if (endDenomBeats === null) {
        setError('End must be a valid position (e.g., 2.1 or 10.1)');
        return;
      }

      // Convert denominator beats to quarter notes
      const startQuarterNotes = startDenomBeats * (4 / denominator);
      const endQuarterNotes = endDenomBeats * (4 / denominator);

      startSeconds = beatsToSeconds(startQuarterNotes, effectiveBpm);
      endSeconds = beatsToSeconds(endQuarterNotes, effectiveBpm);
    } else {
      const parsedStart = parseTimeLocal(startValue);
      const parsedEnd = parseTimeLocal(endValue);

      if (parsedStart === null) {
        setError('Start must be a valid time (e.g., 0:30 or 1:25.500)');
        return;
      }
      if (parsedEnd === null) {
        setError('End must be a valid time (e.g., 1:00 or 2:30.000)');
        return;
      }

      startSeconds = parsedStart;
      endSeconds = parsedEnd;
    }

    // Auto-swap if end < start
    if (endSeconds < startSeconds) {
      [startSeconds, endSeconds] = [endSeconds, startSeconds];
    }

    // Don't allow zero-length selection
    if (Math.abs(endSeconds - startSeconds) < 0.01) {
      setError('Selection must have a length');
      return;
    }

    // Set time selection in REAPER via WebSocket
    sendCommand(timeSelCmd.set(startSeconds, endSeconds));

    // Store locally in beats
    if (effectiveBpm) {
      setTimeSelection({
        startBeats: secondsToBeats(startSeconds, effectiveBpm),
        endBeats: secondsToBeats(endSeconds, effectiveBpm),
      });
    }

    onClose();
  };

  const handleClear = () => {
    sendCommand(timeSelCmd.clear());
    setTimeSelection(null);
    onClose();
  };

  if (!isOpen) return null;

  return (
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4"
      onClick={handleBackdropClick}
    >
      <div
        ref={modalRef}
        className="bg-gray-800 rounded-xl shadow-2xl w-full max-w-sm border border-gray-700"
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-gray-700">
          <h2 className="text-lg font-semibold text-white">Set Time Selection</h2>
          <button
            onClick={onClose}
            className="p-1 text-gray-400 hover:text-white transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Body */}
        <div className="p-4 space-y-4">
          {/* Mode toggle */}
          <div className="flex rounded-lg bg-gray-700 p-1">
            <button
              onClick={() => setMode('beats')}
              className={`flex-1 py-1.5 text-sm font-medium rounded-md transition-colors ${
                mode === 'beats'
                  ? 'bg-gray-600 text-white'
                  : 'text-gray-400 hover:text-white'
              }`}
            >
              Bars.Beats
            </button>
            <button
              onClick={() => setMode('time')}
              className={`flex-1 py-1.5 text-sm font-medium rounded-md transition-colors ${
                mode === 'time'
                  ? 'bg-gray-600 text-white'
                  : 'text-gray-400 hover:text-white'
              }`}
            >
              Time
            </button>
          </div>

          {/* Start and End inputs */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">Start</label>
              <input
                type="text"
                value={startValue}
                onChange={(e) => setStartValue(e.target.value)}
                placeholder={mode === 'beats' ? '1.1' : '0:00.000'}
                autoFocus
                className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-white focus:outline-none focus:border-purple-400"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">End</label>
              <input
                type="text"
                value={endValue}
                onChange={(e) => setEndValue(e.target.value)}
                placeholder={mode === 'beats' ? '2.1' : '0:30.000'}
                className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-white focus:outline-none focus:border-purple-400"
              />
            </div>
          </div>

          {/* Hint */}
          <p className="text-xs text-gray-400">
            {mode === 'beats'
              ? 'Format: bar.beat or bar.beat.ticks (e.g., 5.2 or 5.2.50)'
              : 'Format: MM:SS or HH:MM:SS.mmm (e.g., 1:30 or 0:45.500)'}
          </p>

          {/* Error */}
          {error && (
            <p className="text-sm text-red-400">{error}</p>
          )}
        </div>

        {/* Footer */}
        <div className="flex justify-between px-4 py-3 border-t border-gray-700">
          <button
            onClick={handleClear}
            className="px-4 py-2 text-sm font-medium text-gray-400 hover:text-red-400 transition-colors"
          >
            Clear Selection
          </button>
          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white transition-colors"
            >
              Cancel
            </button>
            <button
              onClick={handleApply}
              className="px-4 py-2 text-sm font-medium text-white bg-purple-600 hover:bg-purple-500 rounded-lg transition-colors"
            >
              Apply
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
