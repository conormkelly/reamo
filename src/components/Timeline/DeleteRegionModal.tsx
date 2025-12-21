/**
 * Delete Region Modal Component
 * Modal dialog for deleting a region with options for handling the gap
 */

import { useState, useEffect, useRef, type ReactElement } from 'react';
import { X, Trash2 } from 'lucide-react';
import { useReaperStore } from '../../store';
import type { Region } from '../../core/types';
import { reaperColorToRgba } from '../../utils';

export type DeleteMode = 'leave-gap' | 'extend-previous' | 'ripple-back';

interface DeleteRegionModalProps {
  isOpen: boolean;
  onClose: () => void;
  region: Region | null;
  regionIndex: number | null;
}

/**
 * Convert seconds to beats (quarter notes)
 */
function secondsToBeats(seconds: number, bpm: number): number {
  return seconds * (bpm / 60);
}

/**
 * Format duration in bars and beats
 * @param denominator - Time signature denominator (default: 4)
 */
function formatDuration(seconds: number, bpm: number, beatsPerBar: number = 4, denominator: number = 4): string {
  // BPM is in quarter notes, convert to denominator beats
  const quarterNoteBeats = secondsToBeats(seconds, bpm);
  const denominatorBeats = quarterNoteBeats * (denominator / 4);
  const totalBeats = Math.round(denominatorBeats * 4) / 4;
  const bars = Math.floor(totalBeats / beatsPerBar);
  const beats = Math.round(totalBeats % beatsPerBar);
  if (bars > 0 && beats > 0) {
    return `${bars} bar${bars !== 1 ? 's' : ''} ${beats} beat${beats !== 1 ? 's' : ''}`;
  } else if (bars > 0) {
    return `${bars} bar${bars !== 1 ? 's' : ''}`;
  } else {
    return `${beats} beat${beats !== 1 ? 's' : ''}`;
  }
}

export function DeleteRegionModal({
  isOpen,
  onClose,
  region,
  regionIndex,
}: DeleteRegionModalProps): ReactElement | null {
  const deleteRegionWithMode = useReaperStore((s) => s.deleteRegionWithMode);
  const regions = useReaperStore((s) => s.regions);
  const getDisplayRegions = useReaperStore((s) => s.getDisplayRegions);
  const bpm = useReaperStore((s) => s.bpm);
  const timeSignature = useReaperStore((s) => s.timeSignature);

  // Parse time signature numerator (beats per bar) and denominator
  const { beatsPerBar, denominator } = (() => {
    const [num, denom] = timeSignature.split('/').map(Number);
    return { beatsPerBar: num || 4, denominator: denom || 4 };
  })();

  const [deleteMode, setDeleteMode] = useState<DeleteMode>('leave-gap');
  const modalRef = useRef<HTMLDivElement>(null);

  // Get display regions to find previous region
  const displayRegions = getDisplayRegions(regions);
  const displayIndex = region ? displayRegions.findIndex((r) => r.id === region.id) : -1;
  const hasPreviousRegion = displayIndex > 0;
  const previousRegion = hasPreviousRegion ? displayRegions[displayIndex - 1] : null;

  // Reset mode when modal opens
  useEffect(() => {
    if (isOpen) {
      setDeleteMode('leave-gap');
    }
  }, [isOpen]);

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

  const handleDelete = () => {
    if (regionIndex === null) return;

    deleteRegionWithMode(regionIndex, deleteMode, regions);
    onClose();
  };

  if (!isOpen || !region) return null;

  const duration = region.end - region.start;
  const durationText = bpm ? formatDuration(duration, bpm, beatsPerBar, denominator) : `${duration.toFixed(2)}s`;

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
          <h2 className="text-lg font-semibold text-white flex items-center gap-2">
            <Trash2 size={20} className="text-red-400" />
            Delete Region
          </h2>
          <button
            onClick={onClose}
            className="p-1 text-gray-400 hover:text-white transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Body */}
        <div className="p-4 space-y-4">
          {/* Region info - simple inline with color accent */}
          <div className="flex items-center gap-3">
            <div
              className="w-1 h-10 rounded-full"
              style={{ backgroundColor: region.color ? reaperColorToRgba(region.color, 1) ?? '#6b7280' : '#6b7280' }}
            />
            <div>
              <div className="text-white font-medium">{region.name}</div>
              <div className="text-sm text-gray-400">{durationText}</div>
            </div>
          </div>

          {/* Delete mode options */}
          <div>
            <div className="space-y-2">
              {/* Leave gap option */}
              <label
                className={`flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors ${
                  deleteMode === 'leave-gap'
                    ? 'border-purple-500 bg-purple-500/10'
                    : 'border-gray-600 hover:border-gray-500'
                }`}
              >
                <input
                  type="radio"
                  name="deleteMode"
                  value="leave-gap"
                  checked={deleteMode === 'leave-gap'}
                  onChange={() => setDeleteMode('leave-gap')}
                  className="mt-1 text-purple-500 focus:ring-purple-500"
                />
                <div>
                  <div className="text-white font-medium">Leave empty space</div>
                  <div className="text-sm text-gray-400">
                    Delete the region and leave a gap in its place
                  </div>
                </div>
              </label>

              {/* Extend previous option */}
              <label
                className={`flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors ${
                  !hasPreviousRegion ? 'opacity-50 cursor-not-allowed' : ''
                } ${
                  deleteMode === 'extend-previous'
                    ? 'border-purple-500 bg-purple-500/10'
                    : 'border-gray-600 hover:border-gray-500'
                }`}
              >
                <input
                  type="radio"
                  name="deleteMode"
                  value="extend-previous"
                  checked={deleteMode === 'extend-previous'}
                  onChange={() => setDeleteMode('extend-previous')}
                  disabled={!hasPreviousRegion}
                  className="mt-1 text-purple-500 focus:ring-purple-500"
                />
                <div>
                  <div className="text-white font-medium">Extend previous region</div>
                  <div className="text-sm text-gray-400">
                    {hasPreviousRegion
                      ? `Extend "${previousRegion?.name}" to fill the gap`
                      : 'No previous region to extend'}
                  </div>
                </div>
              </label>

              {/* Ripple back option */}
              <label
                className={`flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors ${
                  deleteMode === 'ripple-back'
                    ? 'border-purple-500 bg-purple-500/10'
                    : 'border-gray-600 hover:border-gray-500'
                }`}
              >
                <input
                  type="radio"
                  name="deleteMode"
                  value="ripple-back"
                  checked={deleteMode === 'ripple-back'}
                  onChange={() => setDeleteMode('ripple-back')}
                  className="mt-1 text-purple-500 focus:ring-purple-500"
                />
                <div>
                  <div className="text-white font-medium">Ripple delete</div>
                  <div className="text-sm text-gray-400">
                    Delete and shift all following regions back to close the gap
                  </div>
                </div>
              </label>
            </div>
          </div>

          {/* Info about pending state */}
          <p className="text-xs text-center text-gray-400">
            Deletion will be staged as a pending change. Click Save to apply to REAPER.
          </p>
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
            onClick={handleDelete}
            className="px-4 py-2 text-sm font-medium text-white bg-red-600 hover:bg-red-500 rounded-lg transition-colors flex items-center gap-1.5"
          >
            <Trash2 size={16} />
            Delete Region
          </button>
        </div>
      </div>
    </div>
  );
}
