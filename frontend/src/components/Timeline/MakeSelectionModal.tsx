/**
 * Make Selection Modal Component
 * Modal dialog for precisely setting time selection using bar.beat.tick notation.
 * Bar positions are converted by REAPER, through the project's tempo map.
 */

import { useState, useEffect, useRef, type ReactElement } from 'react';
import { useReaper } from '../../hooks/useReaper';
import { useReaperStore } from '../../store';
import { useBarPositions, parseBarPosition } from '../../hooks/useBarPositions';
import { timeSelection as timeSelCmd } from '../../core/WebSocketCommands';
import { Modal } from '../Modal';

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
  const timeSelection = useReaperStore((s) => s.timeSelection);
  const setTimeSelection = useReaperStore((s) => s.setTimeSelection);
  const { barsToSeconds, secondsToBars } = useBarPositions();

  const [mode, setMode] = useState<'beats' | 'time'>('beats');
  const [startValue, setStartValue] = useState('1.1');
  const [endValue, setEndValue] = useState('2.1');
  const [error, setError] = useState<string | null>(null);
  const [applying, setApplying] = useState(false);

  const wasOpenRef = useRef(false);
  // Bumped whenever the form is refilled: a conversion REAPER answers after a
  // later refill (reopen, mode switch) must not overwrite it
  const generationRef = useRef(0);

  // Fill the form when the modal opens: the current selection, or bar 1 to bar 2
  useEffect(() => {
    if (isOpen && !wasOpenRef.current) {
      setError(null);
      const generation = ++generationRef.current;
      const current = generationRef;
      if (mode === 'time') {
        if (timeSelection) {
          setStartValue(formatTimeLocal(timeSelection.startSeconds));
          setEndValue(formatTimeLocal(timeSelection.endSeconds));
        } else {
          setStartValue('0:00.000');
          setEndValue('');
          void barsToSeconds('2.1').then((end) => {
            if (current.current === generation && end !== null) setEndValue(formatTimeLocal(end));
          });
        }
      } else if (timeSelection) {
        setStartValue('');
        setEndValue('');
        void Promise.all([
          secondsToBars(timeSelection.startSeconds),
          secondsToBars(timeSelection.endSeconds),
        ]).then(([start, end]) => {
          if (current.current !== generation) return;
          if (start === null || end === null) {
            setError("Couldn't get the selection's bar positions from REAPER");
            return;
          }
          setStartValue(start);
          setEndValue(end);
        });
      } else {
        setStartValue('1.1');
        setEndValue('2.1');
      }
    }
    wasOpenRef.current = isOpen;
  }, [isOpen, mode, timeSelection, barsToSeconds, secondsToBars]);

  // Switch between bar.beat and time, converting what's typed; a value that
  // doesn't convert is left as typed
  const switchMode = async (next: 'beats' | 'time') => {
    if (next === mode) return;
    const generation = ++generationRef.current;
    setMode(next);
    setError(null);
    const convert = async (value: string): Promise<string | null> => {
      if (next === 'time') {
        const seconds = await barsToSeconds(value);
        return seconds === null ? null : formatTimeLocal(seconds);
      }
      const seconds = parseTimeLocal(value);
      return seconds === null ? null : secondsToBars(seconds);
    };
    const [start, end] = await Promise.all([convert(startValue), convert(endValue)]);
    if (generationRef.current !== generation) return;
    if (start !== null) setStartValue(start);
    if (end !== null) setEndValue(end);
  };

  const handleApply = async () => {
    let startSeconds: number;
    let endSeconds: number;

    if (mode === 'beats') {
      if (!parseBarPosition(startValue)) {
        setError('Start must be a valid position (e.g., 1.1 or 5.2.50)');
        return;
      }
      if (!parseBarPosition(endValue)) {
        setError('End must be a valid position (e.g., 2.1 or 10.1)');
        return;
      }
      setApplying(true);
      const [start, end] = await Promise.all([barsToSeconds(startValue), barsToSeconds(endValue)]);
      setApplying(false);
      if (start === null || end === null) {
        setError(`REAPER couldn't place ${start === null ? 'the start' : 'the end'}: is it before the project start?`);
        return;
      }
      startSeconds = start;
      endSeconds = end;
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

    // Store locally in seconds
    setTimeSelection({
      startSeconds,
      endSeconds,
    });

    onClose();
  };

  const handleClear = () => {
    sendCommand(timeSelCmd.clear());
    setTimeSelection(null);
    onClose();
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Set Time Selection">
      {/* Body */}
      <div className="p-modal space-y-4">
          {/* Mode toggle */}
          <div className="flex rounded-lg bg-bg-elevated p-1">
            <button
              onClick={() => void switchMode('beats')}
              className={`flex-1 py-1.5 text-sm font-medium rounded-md transition-colors ${
                mode === 'beats'
                  ? 'bg-bg-hover text-text-primary'
                  : 'text-text-secondary hover:text-text-primary'
              }`}
            >
              Bars.Beats
            </button>
            <button
              onClick={() => void switchMode('time')}
              className={`flex-1 py-1.5 text-sm font-medium rounded-md transition-colors ${
                mode === 'time'
                  ? 'bg-bg-hover text-text-primary'
                  : 'text-text-secondary hover:text-text-primary'
              }`}
            >
              Time
            </button>
          </div>

          {/* Start and End inputs */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-text-tertiary mb-1">Start</label>
              <input
                type="text"
                value={startValue}
                onChange={(e) => setStartValue(e.target.value)}
                placeholder={mode === 'beats' ? '1.1' : '0:00.000'}
                autoFocus
                className="w-full px-3 py-2 bg-bg-elevated border border-border-default rounded-lg text-text-primary focus:outline-none focus:border-accent-region"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-text-tertiary mb-1">End</label>
              <input
                type="text"
                value={endValue}
                onChange={(e) => setEndValue(e.target.value)}
                placeholder={mode === 'beats' ? '2.1' : '0:30.000'}
                className="w-full px-3 py-2 bg-bg-elevated border border-border-default rounded-lg text-text-primary focus:outline-none focus:border-accent-region"
              />
            </div>
          </div>

          {/* Hint */}
          <p className="text-xs text-text-secondary">
            {mode === 'beats'
              ? 'Format: bar.beat or bar.beat.ticks (e.g., 5.2 or 5.2.50)'
              : 'Format: MM:SS or HH:MM:SS.mmm (e.g., 1:30 or 0:45.500)'}
          </p>

          {/* Error */}
          {error && (
            <p className="text-sm text-error-text">{error}</p>
          )}
        </div>

      {/* Footer */}
      <div className="flex justify-between px-modal-footer-x py-modal-footer-y border-t border-border-subtle">
        <button
          onClick={handleClear}
          className="px-4 py-2 text-sm font-medium text-text-secondary hover:text-error transition-colors"
        >
          Clear Selection
        </button>
        <div className="flex gap-2">
          <button
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-text-tertiary hover:text-text-primary transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={() => void handleApply()}
            disabled={applying}
            className="px-4 py-2 text-sm font-medium text-text-on-accent bg-accent-region hover:bg-accent-region-hover rounded-lg transition-colors"
          >
            Apply
          </button>
        </div>
      </div>
    </Modal>
  );
}
