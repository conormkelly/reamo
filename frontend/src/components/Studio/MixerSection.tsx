/**
 * MixerSection - Mixer content for Studio view
 * Renders track list with meters and controls using horizontal virtualization.
 * Collapse is handled by parent CollapsibleSection wrapper.
 */

import { useState, useMemo, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { useTrackSkeleton } from '../../hooks';
import { MasterTrackStrip, TrackFilter } from '../Track';
import { MixerLockButton, UnselectAllTracksButton } from '../Actions';
import { VirtualizedTrackList } from './VirtualizedTrackList';

export function MixerSection(): ReactElement {
  const [trackFilter, setTrackFilter] = useState('');
  const pinMasterTrack = useReaperStore((s) => s.pinMasterTrack);
  const { totalTracks, filterByName } = useTrackSkeleton();

  // Calculate filtered track count (exclude master for consistency with display)
  const filteredCount = useMemo(() => {
    if (!trackFilter.trim()) return totalTracks;
    const filtered = filterByName(trackFilter);
    // Exclude master track from count
    return filtered.filter((t) => t.g !== 'master').length;
  }, [trackFilter, totalTracks, filterByName]);

  return (
    <>
      {/* Mixer controls - separate line, left-aligned */}
      <div className="flex items-center gap-2 mb-3">
        <TrackFilter
          value={trackFilter}
          onChange={setTrackFilter}
          className="w-1/2 sm:w-40"
          placeholder="Filter..."
          matchCount={filteredCount}
          totalCount={totalTracks}
        />
        <MixerLockButton />
        <UnselectAllTracksButton />
      </div>

      {/* Track list: Master (optionally pinned) + Virtualized user tracks */}
      <div className="flex gap-2 pb-4">
        {pinMasterTrack && <MasterTrackStrip />}
        <VirtualizedTrackList
          filter={trackFilter}
          includeMaster={!pinMasterTrack}
        />
      </div>
    </>
  );
}
