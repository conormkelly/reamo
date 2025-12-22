/**
 * Add Region Modal Component
 * Modal dialog for creating a new region with name, color, start, and length
 */

import { useState, useEffect, useRef, type ReactElement } from 'react';
import { X, RotateCcw } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useBarOffset } from '../../hooks';
import { hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';

// Default region color in REAPER (shown when color = 0)
const DEFAULT_REGION_COLOR = '#688585';

interface AddRegionModalProps {
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
      // Allow beat to be 0 for simplicity, clamp to valid range
      beat = Math.max(1, Math.min(beatsPerBar, beat || 1));
    }
  }

  if (parts.length >= 3 && parts[2] !== '') {
    const ticks = parseInt(parts[2], 10);
    if (!isNaN(ticks)) {
      // Ticks are typically 0-99 representing percentage of beat
      tickFraction = Math.max(0, Math.min(99, ticks)) / 100;
    }
  }

  // Calculate total beats from bar 1
  // Bar 1, beat 1 = 0 beats from start
  const totalBeats = (bar - 1) * beatsPerBar + (beat - 1) + tickFraction;
  return totalBeats;
}

/**
 * Format beats to bar.beat.ticks string
 */
function formatBarBeatTicks(totalBeats: number, beatsPerBar: number = 4): string {
  const bar = Math.floor(totalBeats / beatsPerBar) + 1;
  const beatInBar = totalBeats % beatsPerBar;
  const beat = Math.floor(beatInBar) + 1;
  const ticks = Math.round((beatInBar % 1) * 100);

  if (ticks > 0) {
    return `${bar}.${beat}.${ticks.toString().padStart(2, '0')}`;
  }
  return `${bar}`;
}

export function AddRegionModal({ isOpen, onClose }: AddRegionModalProps): ReactElement | null {
  const createRegion = useReaperStore((s) => s.createRegion);
  const regions = useReaperStore((s) => s.regions);
  const pendingChanges = useReaperStore((s) => s.pendingChanges);
  const getDisplayRegions = useReaperStore((s) => s.getDisplayRegions);
  const bpm = useReaperStore((s) => s.bpm);

  const barOffset = useBarOffset();

  const [name, setName] = useState('New Region');
  const [selectedColor, setSelectedColor] = useState<string | null>(null); // null = REAPER default (gray)
  const [startBar, setStartBar] = useState('1');
  const [lengthBars, setLengthBars] = useState('8');
  const [error, setError] = useState<string | null>(null);

  const modalRef = useRef<HTMLDivElement>(null);
  const wasOpenRef = useRef(false);

  // Get unique colors from existing + pending regions (snapshot when modal opens)
  const existingColorsRef = useRef<string[]>([]);

  // Update colors ref only when modal is closed (so it doesn't change while open)
  useEffect(() => {
    if (!isOpen) {
      const colors = new Set<string>();
      // Use displayRegions to include pending region colors
      const displayRegions = getDisplayRegions(regions);
      displayRegions.forEach((r) => {
        if (r.color) {
          colors.add(reaperColorToHexWithFallback(r.color, DEFAULT_REGION_COLOR));
        }
      });
      existingColorsRef.current = Array.from(colors);
    }
  }, [isOpen, regions, getDisplayRegions]);

  const existingColors = existingColorsRef.current;

  // Reset form only when modal transitions from closed to open
  useEffect(() => {
    if (isOpen && !wasOpenRef.current) {
      // Default start position: end of last region (including pending), or bar 1 if no regions
      let defaultStartSeconds = 0;
      const displayRegions = getDisplayRegions(regions);
      if (displayRegions.length > 0) {
        // Find the end of the last region (by end time, not array order)
        const lastEnd = Math.max(...displayRegions.map(r => r.end));
        defaultStartSeconds = lastEnd;
      }

      // Calculate start position from defaultStartSeconds (with bar offset for projects not starting at bar 1)
      if (bpm && bpm > 0) {
        const beatsPerBar = 4;
        const totalBeats = secondsToBeats(defaultStartSeconds, bpm);
        // Add bar offset (converted to beats)
        const adjustedBeats = totalBeats + barOffset * beatsPerBar;
        setStartBar(formatBarBeatTicks(adjustedBeats, beatsPerBar));
      } else {
        setStartBar('1');
      }
      setName('');
      // Default to REAPER's default color (null = gray)
      setSelectedColor(null);
      setLengthBars('8');
      setError(null);
    }
    wasOpenRef.current = isOpen;
  }, [isOpen, bpm, barOffset, regions, pendingChanges, getDisplayRegions]);

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

  const handleCreate = () => {
    const beatsPerBar = 4;
    const effectiveBpm = bpm && bpm > 0 ? bpm : 120;

    // Parse start position (bar.beat.ticks format)
    const startBeats = parseBarBeatTicks(startBar, beatsPerBar);
    if (startBeats === null) {
      setError('Start must be a valid position (e.g., 69 or 69.2.40)');
      return;
    }

    const lengthBarsNum = parseInt(lengthBars, 10);
    if (isNaN(lengthBarsNum) || lengthBarsNum < 1) {
      setError('Length must be at least 1 bar');
      return;
    }

    // Calculate start and end in seconds (accounting for bar offset)
    // startBeats is from bar 1, need to adjust by barOffset
    const adjustedBeats = startBeats - barOffset * beatsPerBar;
    const start = beatsToSeconds(adjustedBeats, effectiveBpm);
    const end = start + beatsToSeconds(lengthBarsNum * beatsPerBar, effectiveBpm);

    // null = REAPER default (pass undefined to let REAPER assign default color)
    const color = selectedColor ? hexToReaperColor(selectedColor) : undefined;

    // Create the region (as pending change, with ripple logic)
    createRegion(start, end, name.trim(), bpm, color, regions);

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
        className="bg-gray-800 rounded-xl shadow-2xl w-full max-w-md border border-gray-700"
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-gray-700">
          <h2 className="text-lg font-semibold text-white">Add Region</h2>
          <button
            onClick={onClose}
            className="p-1 text-gray-400 hover:text-white transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Body */}
        <div className="p-4 space-y-4">
          {/* Name */}
          <div>
            <label className="block text-sm font-medium text-gray-300 mb-1">Name</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
              className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-white focus:outline-none focus:border-purple-400"
              placeholder="Region name"
            />
          </div>

          {/* Color */}
          <div>
            <label className="block text-sm font-medium text-gray-300 mb-2">Color</label>

            {/* Default + Project colors row */}
            <div className="mb-3">
              <div className="flex gap-2 overflow-x-auto py-1 px-1 -mx-1 items-center">
                {/* Default (reset) color - always first */}
                <button
                  onClick={() => setSelectedColor(null)}
                  className={`w-8 h-8 rounded-lg border-2 transition-all flex-shrink-0 relative ${
                    selectedColor === null
                      ? 'border-white scale-110'
                      : 'border-transparent hover:border-gray-400'
                  }`}
                  style={{ backgroundColor: DEFAULT_REGION_COLOR }}
                  title="Use default color"
                >
                  <RotateCcw size={12} className="absolute inset-0 m-auto text-white/80" />
                </button>

                {/* Existing colors from project */}
                {existingColors.map((color) => (
                  <button
                    key={color}
                    onClick={() => setSelectedColor(color)}
                    className={`w-8 h-8 rounded-lg border-2 transition-all flex-shrink-0 ${
                      selectedColor !== null && selectedColor.toLowerCase() === color.toLowerCase()
                        ? 'border-white scale-110'
                        : 'border-transparent hover:border-gray-400'
                    }`}
                    style={{ backgroundColor: color }}
                  />
                ))}
              </div>
            </div>

            {/* Color picker and hex input */}
            <div>
              <span className="text-xs text-gray-400 mb-1.5 block">Custom</span>
              <div className="flex gap-2 items-center">
                <input
                  type="color"
                  value={selectedColor ?? DEFAULT_REGION_COLOR}
                  onChange={(e) => setSelectedColor(e.target.value)}
                  className="w-10 h-10 rounded-lg border-2 border-gray-600 cursor-pointer bg-transparent"
                  title="Pick a color"
                />
                <input
                  type="text"
                  value={selectedColor ?? ''}
                  onChange={(e) => {
                    const val = e.target.value;
                    if (val === '') {
                      setSelectedColor(null);
                    } else if (/^#[0-9a-f]{0,6}$/i.test(val) || /^[0-9a-f]{0,6}$/i.test(val)) {
                      setSelectedColor(val.startsWith('#') ? val : `#${val}`);
                    }
                  }}
                  placeholder="Default"
                  className="flex-1 px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-white text-sm font-mono focus:outline-none focus:border-purple-400"
                />
              </div>
            </div>
          </div>

          {/* Start and Length */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">Start</label>
              <input
                type="text"
                value={startBar}
                onChange={(e) => setStartBar(e.target.value)}
                placeholder="69.1.40"
                className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-white focus:outline-none focus:border-purple-400"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">Length (bars)</label>
              <input
                type="number"
                min="1"
                value={lengthBars}
                onChange={(e) => setLengthBars(e.target.value)}
                className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-white focus:outline-none focus:border-purple-400"
              />
            </div>
          </div>

          {/* Info about pending state */}
          <p className="text-xs text-gray-400">
            Region will be created as a pending change. Click Save to apply to REAPER.
          </p>

          {/* Error */}
          {error && (
            <p className="text-sm text-red-400">{error}</p>
          )}
        </div>

        {/* Footer */}
        <div className="flex justify-end gap-2 px-4 py-3 border-t border-gray-700">
          <button
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={handleCreate}
            className="px-4 py-2 text-sm font-medium text-white bg-purple-600 hover:bg-purple-500 rounded-lg transition-colors"
          >
            Add Region
          </button>
        </div>
      </div>
    </div>
  );
}
