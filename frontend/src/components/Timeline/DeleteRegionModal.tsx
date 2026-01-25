/**
 * Delete Region Modal Component
 * Modal dialog for deleting a region with options for handling the gap
 */

import { useState, useEffect, type ReactElement } from 'react';
import { Trash2 } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useTimeFormatters } from '../../hooks';
import type { Region } from '../../core/types';
import { reaperColorToRgba } from '../../utils';
import { Modal } from '../Modal';

export type DeleteMode = 'leave-gap' | 'extend-previous' | 'ripple-back';

interface DeleteRegionModalProps {
  isOpen: boolean;
  onClose: () => void;
  region: Region | null;
  regionId: number | null;
}

export function DeleteRegionModal({
  isOpen,
  onClose,
  region,
  regionId,
}: DeleteRegionModalProps): ReactElement | null {
  const deleteRegionWithMode = useReaperStore((s) => s.deleteRegionWithMode);
  const regions = useReaperStore((s) => s.regions);
  const getDisplayRegions = useReaperStore((s) => s.getDisplayRegions);
  const { formatDuration } = useTimeFormatters();

  const [deleteMode, setDeleteMode] = useState<DeleteMode>('leave-gap');

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

  const handleDelete = () => {
    if (regionId === null) return;

    deleteRegionWithMode(regionId, deleteMode, regions);
    onClose();
  };

  if (!region) return null;

  const duration = region.end - region.start;
  const durationText = formatDuration(duration);

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Delete Region"
      icon={<Trash2 size={20} className="text-error" />}
      width="lg"
    >
      {/* Body */}
      <div className="p-modal space-y-4">
          {/* Region info - simple inline with color accent */}
          <div className="flex items-center gap-3">
            <div
              className="w-1 h-10 rounded-full"
              style={{ backgroundColor: region.color ? reaperColorToRgba(region.color, 1) ?? 'var(--color-text-muted)' : 'var(--color-text-muted)' }}
            />
            <div>
              <div className="text-text-primary font-medium">{region.name}</div>
              <div className="text-sm text-text-secondary">{durationText}</div>
            </div>
          </div>

          {/* Delete mode options */}
          <div>
            <div className="space-y-2">
              {/* Leave gap option */}
              <label
                className={`flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors ${
                  deleteMode === 'leave-gap'
                    ? 'border-accent-region bg-accent-region/10'
                    : 'border-border-default hover:border-border-subtle'
                }`}
              >
                <input
                  type="radio"
                  name="deleteMode"
                  value="leave-gap"
                  checked={deleteMode === 'leave-gap'}
                  onChange={() => setDeleteMode('leave-gap')}
                  className="mt-1 text-accent-region focus:ring-accent-region"
                />
                <div>
                  <div className="text-text-primary font-medium">Leave empty space</div>
                  <div className="text-sm text-text-secondary">
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
                    ? 'border-accent-region bg-accent-region/10'
                    : 'border-border-default hover:border-border-subtle'
                }`}
              >
                <input
                  type="radio"
                  name="deleteMode"
                  value="extend-previous"
                  checked={deleteMode === 'extend-previous'}
                  onChange={() => setDeleteMode('extend-previous')}
                  disabled={!hasPreviousRegion}
                  className="mt-1 text-accent-region focus:ring-accent-region"
                />
                <div>
                  <div className="text-text-primary font-medium">Extend previous region</div>
                  <div className="text-sm text-text-secondary">
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
                    ? 'border-accent-region bg-accent-region/10'
                    : 'border-border-default hover:border-border-subtle'
                }`}
              >
                <input
                  type="radio"
                  name="deleteMode"
                  value="ripple-back"
                  checked={deleteMode === 'ripple-back'}
                  onChange={() => setDeleteMode('ripple-back')}
                  className="mt-1 text-accent-region focus:ring-accent-region"
                />
                <div>
                  <div className="text-text-primary font-medium">Ripple delete</div>
                  <div className="text-sm text-text-secondary">
                    Delete and shift all following regions back to close the gap
                  </div>
                </div>
              </label>
            </div>
          </div>

          {/* Info about pending state */}
          <p className="text-xs text-center text-text-secondary">
            Deletion will be staged as a pending change. Click Save to apply to REAPER.
          </p>
        </div>

      {/* Footer */}
      <div className="flex justify-end gap-2 px-modal-footer-x py-modal-footer-y border-t border-border-subtle">
        <button
          onClick={onClose}
          className="px-4 py-2 text-sm font-medium text-text-tertiary hover:text-text-primary transition-colors"
        >
          Cancel
        </button>
        <button
          onClick={handleDelete}
          className="px-4 py-2 text-sm font-medium text-text-on-error bg-error-action hover:bg-error rounded-lg transition-colors flex items-center gap-1.5"
        >
          <Trash2 size={16} />
          Delete Region
        </button>
      </div>
    </Modal>
  );
}
