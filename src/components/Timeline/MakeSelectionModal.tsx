/**
 * Make Selection Modal Component
 * Modal dialog for precisely setting time selection using bar.beat.tick notation
 */

import { useState, useEffect, useRef, type ReactElement } from 'react';
import { X } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import * as commands from '../../core/CommandBuilder';

interface MakeSelectionModalProps {
  isOpen: boolean;
  onClose: () => void;
}

/**
 * Convert beats to seconds
 */
function beatsToSeconds(beats: number, bpm: number): number {
  return beats * (60 / bpm);
}

/**
 * Convert seconds to beats
 */
function secondsToBeats(seconds: number, bpm: number): number {
  return seconds * (bpm / 60);
}

/**
 * Parse REAPER's bar.beat string to get the bar number
 */
function parseReaperBar(positionBeats: string): number {
  const parts = positionBeats.split('.');
  return parseInt(parts[0], 10);
}

/**
 * Parse bar.beat.ticks format to total beats from bar 1
 * Examples: "69" -> bar 69, "69.2" -> bar 69 beat 2, "69.1.40" -> bar 69 beat 1.4
 * Returns beats from the start of bar 1 (0-indexed internally)
 */
function parseBarBeatTicks(input: string, beatsPerBar: number = 4): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;

  const parts = trimmed.split('.');
  const bar = parseInt(parts[0], 10);
  if (isNaN(bar)) return null;

  let beat = 1; // Default to beat 1
  let tickFraction = 0;

  if (parts.length >= 2 && parts[1] !== '') {
    beat = parseInt(parts[1], 10);
    if (isNaN(beat) || beat < 1 || beat > beatsPerBar) {
      beat = Math.max(1, Math.min(beatsPerBar, beat || 1));
    }
  }

  if (parts.length >= 3 && parts[2] !== '') {
    const ticks = parseInt(parts[2], 10);
    if (!isNaN(ticks)) {
      tickFraction = Math.max(0, Math.min(99, ticks)) / 100;
    }
  }

  // Calculate total beats from bar 1
  const totalBeats = (bar - 1) * beatsPerBar + (beat - 1) + tickFraction;
  return totalBeats;
}

/**
 * Format beats to bar.beat.ticks string
 * Handles floating point precision by rounding very small negative values to 0
 */
function formatBarBeatTicks(totalBeats: number, beatsPerBar: number = 4): string {
  // Handle floating point precision - round very small negatives to 0
  const roundedBeats = Math.abs(totalBeats) < 0.001 ? 0 : totalBeats;
  // Round to avoid floating point issues (e.g., 19.9995 → 20)
  const snappedBeats = Math.round(roundedBeats * 100) / 100;

  const bar = Math.floor(snappedBeats / beatsPerBar) + 1;
  const beatInBar = snappedBeats - Math.floor(snappedBeats / beatsPerBar) * beatsPerBar;
  const beat = Math.floor(beatInBar) + 1;
  const ticks = Math.round((beatInBar % 1) * 100);

  if (ticks > 0) {
    return `${bar}.${beat}.${ticks.toString().padStart(2, '0')}`;
  }
  return `${bar}.${beat}`;
}

/**
 * Format seconds to time string (MM:SS.mmm or HH:MM:SS.mmm)
 */
function formatTime(seconds: number): string {
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
function parseTime(input: string): number | null {
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
  const { send } = useReaper();
  const bpm = useReaperStore((s) => s.bpm);
  const positionBeats = useReaperStore((s) => s.positionBeats);
  const positionSeconds = useReaperStore((s) => s.positionSeconds);
  const timeSelection = useReaperStore((s) => s.timeSelection);
  const setTimeSelection = useReaperStore((s) => s.setTimeSelection);

  // Calculate bar offset from REAPER's actual bar numbering
  const barOffset = (() => {
    if (!bpm || !positionBeats) return 0;
    if (positionSeconds < 0) return 0;
    const actualBar = parseReaperBar(positionBeats);
    const rawBeats = secondsToBeats(positionSeconds, bpm);
    const totalBeats = Math.round(rawBeats * 4) / 4;
    const calculatedBar = Math.floor(totalBeats / 4) + 1;
    return actualBar - calculatedBar;
  })();

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
      const beatsPerBar = 4;

      // Pre-populate with current time selection if exists
      if (timeSelection) {
        const startSeconds = beatsToSeconds(timeSelection.startBeats, effectiveBpm);
        const endSeconds = beatsToSeconds(timeSelection.endBeats, effectiveBpm);

        if (mode === 'beats') {
          const startBeatsAdjusted = timeSelection.startBeats + capturedBarOffsetRef.current * beatsPerBar;
          const endBeatsAdjusted = timeSelection.endBeats + capturedBarOffsetRef.current * beatsPerBar;
          setStartValue(formatBarBeatTicks(startBeatsAdjusted, beatsPerBar));
          setEndValue(formatBarBeatTicks(endBeatsAdjusted, beatsPerBar));
        } else {
          setStartValue(formatTime(startSeconds));
          setEndValue(formatTime(endSeconds));
        }
      } else {
        // Default to bar 1 to bar 2
        if (mode === 'beats') {
          setStartValue('1.1');
          setEndValue('2.1');
        } else {
          setStartValue('0:00.000');
          setEndValue(formatTime(beatsToSeconds(4, effectiveBpm)));
        }
      }
    }
    wasOpenRef.current = isOpen;
  }, [isOpen, bpm, barOffset, timeSelection, mode]);

  // Convert values when mode changes while modal is open
  useEffect(() => {
    if (!isOpen) return;
    if (mode === prevModeRef.current) return;

    const prevMode = prevModeRef.current;
    prevModeRef.current = mode;

    const effectiveBpm = bpm && bpm > 0 ? bpm : 120;
    const beatsPerBar = 4;
    // Use captured barOffset to ensure consistent conversions
    const offset = capturedBarOffsetRef.current;

    // Convert start value
    let startSeconds: number | null = null;
    let endSeconds: number | null = null;

    if (prevMode === 'beats') {
      // Parse from bar.beat format
      const startBeats = parseBarBeatTicks(startValue, beatsPerBar);
      const endBeats = parseBarBeatTicks(endValue, beatsPerBar);

      if (startBeats !== null) {
        const adjustedStartBeats = startBeats - offset * beatsPerBar;
        startSeconds = beatsToSeconds(adjustedStartBeats, effectiveBpm);
      }
      if (endBeats !== null) {
        const adjustedEndBeats = endBeats - offset * beatsPerBar;
        endSeconds = beatsToSeconds(adjustedEndBeats, effectiveBpm);
      }
    } else {
      // Parse from time format
      startSeconds = parseTime(startValue);
      endSeconds = parseTime(endValue);
    }

    // Format to new mode
    if (mode === 'time') {
      // Convert to time format
      if (startSeconds !== null) {
        setStartValue(formatTime(startSeconds));
      }
      if (endSeconds !== null) {
        setEndValue(formatTime(endSeconds));
      }
    } else {
      // Convert to bar.beat format
      if (startSeconds !== null) {
        const startBeats = secondsToBeats(startSeconds, effectiveBpm) + offset * beatsPerBar;
        setStartValue(formatBarBeatTicks(startBeats, beatsPerBar));
      }
      if (endSeconds !== null) {
        const endBeats = secondsToBeats(endSeconds, effectiveBpm) + offset * beatsPerBar;
        setEndValue(formatBarBeatTicks(endBeats, beatsPerBar));
      }
    }

    setError(null);
  }, [mode, isOpen, bpm, startValue, endValue]);

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
    const beatsPerBar = 4;
    const effectiveBpm = bpm && bpm > 0 ? bpm : 120;
    // Use captured barOffset for consistency
    const offset = capturedBarOffsetRef.current;

    let startSeconds: number;
    let endSeconds: number;

    if (mode === 'beats') {
      const startBeats = parseBarBeatTicks(startValue, beatsPerBar);
      const endBeats = parseBarBeatTicks(endValue, beatsPerBar);

      if (startBeats === null) {
        setError('Start must be a valid position (e.g., 1.1 or 5.2.50)');
        return;
      }
      if (endBeats === null) {
        setError('End must be a valid position (e.g., 2.1 or 10.1)');
        return;
      }

      // Adjust for bar offset
      const adjustedStartBeats = startBeats - offset * beatsPerBar;
      const adjustedEndBeats = endBeats - offset * beatsPerBar;

      startSeconds = beatsToSeconds(adjustedStartBeats, effectiveBpm);
      endSeconds = beatsToSeconds(adjustedEndBeats, effectiveBpm);
    } else {
      const parsedStart = parseTime(startValue);
      const parsedEnd = parseTime(endValue);

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

    // Set time selection in REAPER
    const cmds = commands.join(
      commands.setPosition(startSeconds),
      commands.setTimeSelectionStart(),
      commands.setPosition(endSeconds),
      commands.setTimeSelectionEnd(),
      commands.setPosition(startSeconds) // Return to start
    );
    send(cmds);

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
    send(commands.clearTimeSelection());
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
