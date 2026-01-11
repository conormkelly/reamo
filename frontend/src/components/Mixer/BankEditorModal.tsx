/**
 * BankEditorModal - Create/Edit custom track banks
 * Supports two bank types:
 * - Smart Bank: auto-matches tracks by name pattern
 * - Custom Bank: manually selected tracks
 */

import { useState, useEffect, useMemo, useCallback, type ReactElement } from 'react';
import { Layers, Zap, List, AlertTriangle, X } from 'lucide-react';
import { Modal, ModalContent, ModalFooter } from '../Modal';
import { useTrackSkeleton } from '../../hooks';
import type { CustomBank, BankType } from './BankSelector';

/** Generate a unique ID (works without HTTPS on iOS) */
function generateBankId(): string {
  return `bank_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

export interface BankEditorModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Called when bank is saved */
  onSave: (bank: CustomBank) => Promise<void>;
  /** Called when bank is deleted (edit mode only) */
  onDelete?: (bankId: string) => Promise<void>;
  /** Existing bank to edit (null for create mode) */
  editBank?: CustomBank | null;
}

/**
 * Modal for creating and editing track banks.
 * Uses track skeleton to show ALL tracks regardless of subscription state.
 */
export function BankEditorModal({
  isOpen,
  onClose,
  onSave,
  onDelete,
  editBank,
}: BankEditorModalProps): ReactElement {
  const { skeleton } = useTrackSkeleton();
  const isEditMode = !!editBank;

  // Form state
  const [name, setName] = useState('');
  const [bankType, setBankType] = useState<BankType>('smart');
  const [pattern, setPattern] = useState('');
  const [selectedGuids, setSelectedGuids] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Filter state for custom bank track list
  const [filterQuery, setFilterQuery] = useState('');

  // All tracks with indices (exclude master at index 0)
  const allTracks = useMemo(
    () => skeleton.slice(1).map((t, i) => ({ ...t, trackNum: i + 1 })),
    [skeleton]
  );

  // Track number width for justified display (e.g., 2 digits for <100 tracks, 3 for <1000)
  const trackNumWidth = useMemo(() => String(allTracks.length).length, [allTracks.length]);

  // Set of all current track GUIDs for detecting missing tracks
  const currentTrackGuids = useMemo(() => new Set(allTracks.map((t) => t.g)), [allTracks]);

  // Initialize form when modal opens or editBank changes
  useEffect(() => {
    if (isOpen) {
      if (editBank) {
        setName(editBank.name);
        setBankType(editBank.type);
        setPattern(editBank.pattern ?? '');
        setSelectedGuids(new Set(editBank.trackGuids));
      } else {
        setName('');
        setBankType('smart');
        setPattern('');
        setSelectedGuids(new Set());
      }
      setFilterQuery('');
      setError(null);
    }
  }, [isOpen, editBank]);

  // Smart bank: tracks matching the pattern (live preview)
  const smartMatchedTracks = useMemo(() => {
    if (bankType !== 'smart' || !pattern.trim()) return [];
    const lower = pattern.toLowerCase();
    return allTracks.filter((t) => t.n.toLowerCase().includes(lower));
  }, [bankType, pattern, allTracks]);

  // Custom bank: filtered tracks for selection list
  const filteredTracks = useMemo(() => {
    if (!filterQuery.trim()) return allTracks;
    const lower = filterQuery.toLowerCase();
    return allTracks.filter((t) => t.n.toLowerCase().includes(lower));
  }, [allTracks, filterQuery]);

  // Custom bank: missing tracks (GUIDs in bank but not in project)
  const missingTrackGuids = useMemo(() => {
    if (bankType !== 'custom') return [];
    return Array.from(selectedGuids).filter((guid) => !currentTrackGuids.has(guid));
  }, [bankType, selectedGuids, currentTrackGuids]);

  // Toggle track selection (custom bank)
  const toggleTrack = useCallback((guid: string) => {
    setSelectedGuids((prev) => {
      const next = new Set(prev);
      if (next.has(guid)) {
        next.delete(guid);
      } else {
        next.add(guid);
      }
      return next;
    });
  }, []);

  // Select all visible tracks (custom bank)
  const selectAll = useCallback(() => {
    setSelectedGuids((prev) => {
      const next = new Set(prev);
      filteredTracks.forEach((t) => next.add(t.g));
      return next;
    });
  }, [filteredTracks]);

  // Deselect all visible tracks (custom bank)
  const deselectAll = useCallback(() => {
    setSelectedGuids((prev) => {
      const next = new Set(prev);
      filteredTracks.forEach((t) => next.delete(t.g));
      return next;
    });
  }, [filteredTracks]);

  // Remove a missing track GUID
  const removeMissingTrack = useCallback((guid: string) => {
    setSelectedGuids((prev) => {
      const next = new Set(prev);
      next.delete(guid);
      return next;
    });
  }, []);

  // Remove all missing tracks
  const removeAllMissing = useCallback(() => {
    setSelectedGuids((prev) => {
      const next = new Set(prev);
      missingTrackGuids.forEach((guid) => next.delete(guid));
      return next;
    });
  }, [missingTrackGuids]);

  // Check if all visible tracks are selected (custom bank)
  const allSelected = useMemo(
    () => filteredTracks.length > 0 && filteredTracks.every((t) => selectedGuids.has(t.g)),
    [filteredTracks, selectedGuids]
  );

  // Validation
  const isValid = useMemo(() => {
    if (!name.trim()) return false;
    if (bankType === 'smart') {
      // Smart bank just needs a pattern (can match zero tracks for now)
      return pattern.trim().length > 0;
    } else {
      // Custom bank: need at least one existing track selected
      const existingSelected = Array.from(selectedGuids).filter((g) => currentTrackGuids.has(g));
      return existingSelected.length > 0;
    }
  }, [name, bankType, pattern, selectedGuids, currentTrackGuids]);

  // Handle save
  const handleSave = useCallback(async () => {
    if (!name.trim()) {
      setError('Bank name is required');
      return;
    }

    if (bankType === 'smart') {
      if (!pattern.trim()) {
        setError('Match pattern is required');
        return;
      }
      // Allow smart banks with no current matches (user may be setting up project)
    } else {
      const existingSelected = Array.from(selectedGuids).filter((g) => currentTrackGuids.has(g));
      if (existingSelected.length === 0) {
        setError('Select at least one track');
        return;
      }
    }

    setSaving(true);
    setError(null);

    try {
      const bank: CustomBank = {
        id: editBank?.id ?? generateBankId(),
        name: name.trim(),
        type: bankType,
        pattern: bankType === 'smart' ? pattern.trim() : undefined,
        // For custom banks, filter out missing tracks on save
        trackGuids:
          bankType === 'smart'
            ? []
            : Array.from(selectedGuids).filter((g) => currentTrackGuids.has(g)),
      };

      await onSave(bank);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save bank');
    } finally {
      setSaving(false);
    }
  }, [name, bankType, pattern, smartMatchedTracks, selectedGuids, currentTrackGuids, editBank, onSave, onClose]);

  // Handle delete
  const handleDelete = useCallback(async () => {
    if (!editBank || !onDelete) return;

    if (!confirm(`Delete bank "${editBank.name}"?`)) return;

    setSaving(true);
    setError(null);

    try {
      await onDelete(editBank.id);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete bank');
      setSaving(false);
    }
  }, [editBank, onDelete, onClose]);

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Bank' : 'New Bank'}
      icon={<Layers size={18} className="text-primary" />}
      width="lg"
    >
      <ModalContent>
        {/* Bank name input */}
        <div>
          <label className="block text-sm text-text-secondary mb-1">Bank Name</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g., Drums, Vocals, Guitars..."
            className="w-full px-3 py-2 bg-bg-surface border border-border-subtle rounded-lg text-text-primary placeholder-text-muted focus:outline-none focus:border-primary"
            autoFocus
          />
        </div>

        {/* Bank type selector */}
        <div>
          <label className="block text-sm text-text-secondary mb-2">Bank Type</label>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => setBankType('smart')}
              className={`flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-lg border transition-colors ${
                bankType === 'smart'
                  ? 'bg-primary/10 border-primary text-primary'
                  : 'bg-bg-surface border-border-subtle text-text-secondary hover:border-border-default'
              }`}
            >
              <Zap size={16} />
              <span className="text-sm font-medium">Smart Bank</span>
            </button>
            <button
              type="button"
              onClick={() => setBankType('custom')}
              className={`flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-lg border transition-colors ${
                bankType === 'custom'
                  ? 'bg-primary/10 border-primary text-primary'
                  : 'bg-bg-surface border-border-subtle text-text-secondary hover:border-border-default'
              }`}
            >
              <List size={16} />
              <span className="text-sm font-medium">Custom Bank</span>
            </button>
          </div>
          <p className="text-xs text-text-muted mt-1">
            {bankType === 'smart'
              ? 'Auto-matches tracks by name and updates when tracks change.'
              : 'Manually select specific tracks.'}
          </p>
        </div>

        {/* Smart Bank: Pattern input + preview */}
        {bankType === 'smart' && (
          <div>
            <label className="block text-sm text-text-secondary mb-1">Match Pattern</label>
            <input
              type="text"
              value={pattern}
              onChange={(e) => setPattern(e.target.value)}
              placeholder="e.g., drum, vox, guitar..."
              className="w-full px-3 py-2 bg-bg-surface border border-border-subtle rounded-lg text-text-primary placeholder-text-muted focus:outline-none focus:border-primary"
            />
            <p className="text-xs text-text-muted mt-1">
              Matches track names containing this text (case-insensitive)
            </p>

            {/* Live preview */}
            <div className="mt-3">
              <label className="block text-sm text-text-secondary mb-1">
                Preview ({smartMatchedTracks.length} tracks match)
              </label>
              <div className="max-h-40 overflow-y-auto border border-border-subtle rounded-lg bg-bg-surface">
                {smartMatchedTracks.length === 0 ? (
                  <div className="p-3 text-center text-text-muted text-sm">
                    {pattern.trim() ? 'No tracks currently match this pattern' : 'Enter a pattern to see matches'}
                  </div>
                ) : (
                  smartMatchedTracks.map((track, idx) => (
                    <div
                      key={track.g}
                      className={`flex items-center justify-between px-3 py-1.5 text-sm ${
                        idx !== smartMatchedTracks.length - 1 ? 'border-b border-border-subtle' : ''
                      }`}
                    >
                      <span className="text-text-primary truncate">
                        {track.n || `Track ${track.trackNum}`}
                      </span>
                      <span
                        className="text-text-muted font-mono ml-2 flex-shrink-0"
                        style={{ minWidth: `${trackNumWidth}ch` }}
                      >
                        {String(track.trackNum).padStart(trackNumWidth, '\u2007')}
                      </span>
                    </div>
                  ))
                )}
              </div>
            </div>
          </div>
        )}

        {/* Custom Bank: Track selection */}
        {bankType === 'custom' && (
          <>
            <div>
              <div className="flex items-center justify-between mb-2">
                <label className="text-sm text-text-secondary">
                  Select Tracks ({Array.from(selectedGuids).filter((g) => currentTrackGuids.has(g)).length} selected)
                </label>
                <button
                  type="button"
                  onClick={allSelected ? deselectAll : selectAll}
                  className="text-xs text-primary hover:text-primary-hover"
                >
                  {allSelected ? 'Deselect All' : 'Select All'}
                </button>
              </div>

              {/* Filter input */}
              <input
                type="text"
                value={filterQuery}
                onChange={(e) => setFilterQuery(e.target.value)}
                placeholder="Filter tracks..."
                className="w-full px-3 py-1.5 mb-2 bg-bg-elevated border border-border-subtle rounded text-sm text-text-primary placeholder-text-muted focus:outline-none focus:border-border-default"
              />

              {/* Track list */}
              <div className="max-h-48 overflow-y-auto border border-border-subtle rounded-lg bg-bg-surface">
                {filteredTracks.length === 0 ? (
                  <div className="p-4 text-center text-text-muted text-sm">
                    {allTracks.length === 0 ? 'No tracks in project' : 'No tracks match filter'}
                  </div>
                ) : (
                  filteredTracks.map((track, idx) => (
                    <label
                      key={track.g}
                      className={`flex items-center gap-3 px-3 py-2 cursor-pointer hover:bg-bg-elevated transition-colors ${
                        idx !== filteredTracks.length - 1 ? 'border-b border-border-subtle' : ''
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={selectedGuids.has(track.g)}
                        onChange={() => toggleTrack(track.g)}
                        className="w-4 h-4 rounded border-border-subtle text-primary focus:ring-primary focus:ring-offset-0 bg-bg-elevated flex-shrink-0"
                      />
                      <span className="text-sm text-text-primary truncate flex-1">
                        {track.n || `Track ${track.trackNum}`}
                      </span>
                      <span
                        className="text-xs text-text-muted font-mono flex-shrink-0"
                        style={{ minWidth: `${trackNumWidth}ch` }}
                      >
                        {String(track.trackNum).padStart(trackNumWidth, '\u2007')}
                      </span>
                    </label>
                  ))
                )}
              </div>
            </div>

            {/* Missing tracks warning */}
            {missingTrackGuids.length > 0 && (
              <div className="bg-warning/10 border border-warning/30 rounded-lg p-3">
                <div className="flex items-center justify-between mb-2">
                  <div className="flex items-center gap-2 text-warning">
                    <AlertTriangle size={16} />
                    <span className="text-sm font-medium">
                      Missing Tracks ({missingTrackGuids.length})
                    </span>
                  </div>
                  <button
                    type="button"
                    onClick={removeAllMissing}
                    className="text-xs text-warning hover:text-warning/80"
                  >
                    Remove All
                  </button>
                </div>
                <p className="text-xs text-text-muted mb-2">
                  These tracks no longer exist in the project:
                </p>
                <div className="space-y-1">
                  {missingTrackGuids.map((guid) => (
                    <div
                      key={guid}
                      className="flex items-center justify-between bg-bg-surface/50 rounded px-2 py-1"
                    >
                      <span className="text-xs text-text-muted font-mono truncate">
                        {guid.slice(0, 16)}...
                      </span>
                      <button
                        type="button"
                        onClick={() => removeMissingTrack(guid)}
                        className="p-0.5 text-text-muted hover:text-error"
                      >
                        <X size={12} />
                      </button>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </>
        )}
      </ModalContent>

      <ModalFooter
        onCancel={onClose}
        onConfirm={handleSave}
        confirmText={isEditMode ? 'Save' : 'Create'}
        confirmDisabled={!isValid}
        confirmLoading={saving}
        leftContent={
          <>
            {isEditMode && onDelete && (
              <button
                type="button"
                onClick={handleDelete}
                disabled={saving}
                className="text-sm text-error-action hover:text-error disabled:opacity-50"
              >
                Delete Bank
              </button>
            )}
            {error && <span className="text-sm text-error ml-2">{error}</span>}
          </>
        }
      />
    </Modal>
  );
}
