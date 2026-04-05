/**
 * Add Region Modal Component
 * Modal dialog for creating a new region with name, color, start, and length
 */

import { useState, useEffect, useRef, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { tempo as tempoCmd } from '../../core/WebSocketCommands';
import {
  hexToReaperColor,
} from '../../utils';
import { DEFAULT_REGION_COLOR } from '../../constants/colors';
import { Modal, ModalFooter } from '../Modal';

interface AddRegionModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export function AddRegionModal({ isOpen, onClose }: AddRegionModalProps): ReactElement | null {
  const { sendCommandAsync } = useReaper();
  const createRegion = useReaperStore((s) => s.createRegion);
  const regions = useReaperStore((s) => s.regions);
  const pendingChanges = useReaperStore((s) => s.pendingChanges);
  const getDisplayRegions = useReaperStore((s) => s.getDisplayRegions);
  const bpm = useReaperStore((s) => s.bpm);

  const [name, setName] = useState('New Region');
  const [selectedColor, setSelectedColor] = useState<string | null>(null); // null = REAPER default (gray)
  const [startBar, setStartBar] = useState('1');
  const [lengthBars, setLengthBars] = useState('8');
  const [error, setError] = useState<string | null>(null);

  const wasOpenRef = useRef(false);

  // Hold-to-reset for color swatch
  const holdTimer = useRef<number | null>(null);
  const didReset = useRef(false);
  const customColorRef = useRef<HTMLInputElement>(null);
  const HOLD_DURATION = 500;

  // Cleanup timers on unmount
  useEffect(() => {
    return () => {
      if (holdTimer.current) clearTimeout(holdTimer.current);
    };
  }, []);

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

      // Use server's timeToBeats for accurate bar string (handles tempo changes)
      sendCommandAsync(tempoCmd.timeToBeats(defaultStartSeconds))
        .then((response) => {
          const resp = response as { payload?: { bars?: string } } | undefined;
          if (resp?.payload?.bars) {
            // Strip trailing .00 ticks for cleaner display
            setStartBar(resp.payload.bars.replace(/\.00$/, ''));
          } else {
            setStartBar('1');
          }
        })
        .catch(() => {
          // Fallback to bar 1 on error
          setStartBar('1');
        });

      setName('');
      // Default to REAPER's default color (null = gray)
      setSelectedColor(null);
      setLengthBars('8');
      setError(null);
    }
    wasOpenRef.current = isOpen;
  }, [isOpen, regions, pendingChanges, getDisplayRegions, sendCommandAsync]);

  const handleCreate = async () => {
    // Parse start position (bar.beat.ticks format)
    const startParts = startBar.split('.');
    const startBarNum = parseInt(startParts[0], 10);
    if (isNaN(startBarNum)) {
      setError('Start must be a valid position (e.g., 69 or 69.2.40)');
      return;
    }
    const startBeat = startParts.length >= 2 ? parseInt(startParts[1], 10) : 1;
    const startTicks = startParts.length >= 3 ? parseInt(startParts[2], 10) : 0;

    const lengthBarsNum = parseInt(lengthBars, 10);
    if (isNaN(lengthBarsNum) || lengthBarsNum < 1) {
      setError('Length must be at least 1 bar');
      return;
    }

    try {
      // Use server's tempo/barsToTime for accurate start time (handles tempo changes)
      const startResponse = await sendCommandAsync(tempoCmd.barsToTime(startBarNum, startBeat, startTicks));
      const startResp = startResponse as { payload?: { time?: number } } | undefined;
      if (startResp?.payload?.time === undefined) {
        setError('Failed to calculate start time');
        return;
      }
      const start = startResp.payload.time;

      // Calculate end position: add duration bars to start position
      // End bar = start bar + duration bars, beat and ticks stay same
      const endBarNum = startBarNum + lengthBarsNum;
      const endResponse = await sendCommandAsync(tempoCmd.barsToTime(endBarNum, startBeat, startTicks));
      const endResp = endResponse as { payload?: { time?: number } } | undefined;
      if (endResp?.payload?.time === undefined) {
        setError('Failed to calculate end time');
        return;
      }
      const end = endResp.payload.time;

      // null = REAPER default (pass undefined to let REAPER assign default color)
      const color = selectedColor ? hexToReaperColor(selectedColor) : undefined;

      // Create the region (as pending change, with ripple logic)
      createRegion(start, end, name.trim(), bpm, color, regions);

      onClose();
    } catch {
      setError('Failed to calculate position');
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Add Region"
      width="sm"
      className="max-h-[85dvh] flex flex-col"
    >
      {/* Scrollable content */}
      <div className="p-modal space-y-4 overflow-y-auto flex-1">
        {/* Name */}
        <div>
          <label className="block text-sm font-medium text-text-tertiary mb-1">Name</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
            className="w-full px-3 py-2 bg-bg-elevated border border-border-default rounded-lg text-text-primary text-base focus:outline-none focus:border-accent-region"
            placeholder="Region name"
          />
        </div>

        {/* Color - tap to pick, hold to reset (matching MarkerEditModal pattern) */}
        <div className="flex items-center gap-3">
          <label className="text-sm font-medium text-text-tertiary">Color</label>
          <div
            onMouseDown={() => {
              didReset.current = false;
              holdTimer.current = window.setTimeout(() => {
                setSelectedColor(null);
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
                setSelectedColor(null);
                didReset.current = true;
              }, HOLD_DURATION);
            }}
            onTouchEnd={() => {
              if (holdTimer.current) { clearTimeout(holdTimer.current); holdTimer.current = null; }
              if (!didReset.current) customColorRef.current?.click();
            }}
            className="relative w-10 h-10 rounded-lg border-2 border-border-default cursor-pointer hover:border-text-secondary transition-colors touch-none"
            style={{ backgroundColor: selectedColor ?? DEFAULT_REGION_COLOR }}
            title={selectedColor === null ? 'Tap to pick color' : `${selectedColor} (hold to reset)`}
          >
            {/* Non-default indicator dot */}
            {selectedColor !== null && (
              <div className="absolute -top-1 -right-1 w-3 h-3 bg-primary-hover rounded-full border border-bg-surface" />
            )}
            <input
              ref={customColorRef}
              type="color"
              value={selectedColor ?? DEFAULT_REGION_COLOR}
              onChange={(e) => setSelectedColor(e.target.value)}
              className="absolute inset-0 opacity-0 cursor-pointer"
              tabIndex={-1}
            />
          </div>
        </div>

        {/* Start and Length */}
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-text-tertiary mb-1">Start</label>
            <input
              type="text"
              value={startBar}
              onChange={(e) => setStartBar(e.target.value)}
              placeholder="69.1.40"
              className="w-full px-3 py-2 bg-bg-elevated border border-border-default rounded-lg text-text-primary text-base focus:outline-none focus:border-accent-region"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-text-tertiary mb-1">Length (bars)</label>
            <input
              type="number"
              min="1"
              value={lengthBars}
              onChange={(e) => setLengthBars(e.target.value)}
              className="w-full px-3 py-2 bg-bg-elevated border border-border-default rounded-lg text-text-primary text-base focus:outline-none focus:border-accent-region"
            />
          </div>
        </div>

        {/* Info about pending state */}
        <p className="text-xs text-text-secondary">
          Region will be created as a pending change. Click Save to apply to REAPER.
        </p>

        {/* Error */}
        {error && (
          <p className="text-sm text-error-text">{error}</p>
        )}
      </div>

      <ModalFooter
        onCancel={onClose}
        onConfirm={handleCreate}
        confirmText="Add Region"
      />
    </Modal>
  );
}
