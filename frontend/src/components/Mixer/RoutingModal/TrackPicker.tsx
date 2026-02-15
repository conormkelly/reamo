/**
 * TrackPicker - Inline track selection list for routing creation
 * Renders within the tab content area when user wants to add a send/receive.
 */

import { useState, useMemo, type ReactElement } from 'react';
import { useTrackSkeleton } from '../../../hooks';

export interface TrackPickerProps {
  /** Called when user selects a track */
  onSelect: (trackGuid: string) => void;
  /** Called when user cancels */
  onCancel: () => void;
  /** GUID of current track (excluded from list) */
  excludeGuid: string;
  /** Prompt text shown at top */
  prompt: string;
}

export function TrackPicker({
  onSelect,
  onCancel,
  excludeGuid,
  prompt,
}: TrackPickerProps): ReactElement {
  const [search, setSearch] = useState('');
  const { filterByName } = useTrackSkeleton();

  const filtered = useMemo(() => {
    return filterByName(search).filter(
      (t) => t.g !== excludeGuid && t.g !== 'master'
    );
  }, [filterByName, search, excludeGuid]);

  return (
    <div className="space-y-2">
      {/* Header */}
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium text-text-primary">{prompt}</span>
        <button
          onClick={onCancel}
          className="text-xs text-text-muted px-2 py-1 rounded hover:bg-bg-elevated"
        >
          Cancel
        </button>
      </div>

      {/* Search */}
      <input
        type="text"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder="Search tracks..."
        autoFocus
        className="w-full px-3 py-2 rounded-lg bg-bg-surface border border-border-subtle text-base text-text-primary placeholder:text-text-muted focus:outline-none focus:border-accent-primary"
      />

      {/* Track list */}
      <div className="max-h-56 overflow-y-auto space-y-0.5">
        {filtered.length === 0 && (
          <p className="text-center text-text-muted text-sm py-4">
            No tracks found
          </p>
        )}
        {filtered.map((track) => (
          <button
            key={track.g}
            onClick={() => onSelect(track.g)}
            className="w-full text-left px-3 py-2.5 rounded-lg text-sm hover:bg-bg-elevated active:bg-bg-surface transition-colors flex items-center gap-2"
          >
            <span className="text-text-muted text-xs w-5 text-right shrink-0">
              {track.index}
            </span>
            <span className="text-text-primary truncate">
              {track.n || `Track ${track.index}`}
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}
