/**
 * MixerSection - Mixer content for Studio view
 * Renders track list with meters and controls using horizontal virtualization.
 * Collapse is handled by parent CollapsibleSection wrapper.
 */

import { useState, useMemo, type ReactElement } from 'react';
import { Lock, Unlock, XCircle } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTracks, useTrackSkeleton } from '../../hooks';
import { track as trackCmd } from '../../core/WebSocketCommands';
import { TrackStrip, LevelMeter, TrackFilter } from '../Track';
import { VirtualizedTrackList } from './VirtualizedTrackList';

/** Master track strip with meter (always visible, not virtualized) */
function MasterTrackStrip() {
  return (
    <div className="flex gap-1 flex-shrink-0">
      <LevelMeter trackIndex={0} height={200} />
      <TrackStrip trackIndex={0} />
    </div>
  );
}

function MixerLockButton() {
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const toggleMixerLock = useReaperStore((s) => s.toggleMixerLock);

  return (
    <button
      onClick={toggleMixerLock}
      className={`p-2 rounded transition-colors ${
        mixerLocked
          ? 'bg-yellow-600 text-white'
          : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
      }`}
      title={mixerLocked ? 'Unlock mixer controls' : 'Lock mixer controls'}
    >
      {mixerLocked ? <Lock size={18} /> : <Unlock size={18} />}
    </button>
  );
}

function UnselectAllTracksButton() {
  const { sendCommand } = useReaper();
  const { selectedTracks } = useTracks();

  // Only show when tracks are selected
  if (selectedTracks.length === 0) return null;

  return (
    <button
      onClick={() => sendCommand(trackCmd.unselectAll())}
      className="p-2 rounded transition-colors bg-gray-700 text-gray-300 hover:bg-gray-600"
      title="Deselect all tracks"
    >
      <XCircle size={18} />
    </button>
  );
}

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
