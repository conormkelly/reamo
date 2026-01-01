/**
 * MixerSection - Mixer content for Studio view
 * Renders track list with meters and controls
 * Collapse is handled by parent CollapsibleSection wrapper
 */

import { useState, useMemo, type ReactElement } from 'react';
import { Lock, Unlock, XCircle } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTracks } from '../../hooks';
import { track as trackCmd } from '../../core/WebSocketCommands';
import { TrackStrip, LevelMeter, TrackFilter } from '../Track';

function TrackList({ filter }: { filter: string }) {
  const { userTracks } = useTracks();

  const filteredTracks = useMemo(() => {
    if (!filter.trim()) return userTracks;
    const lowerFilter = filter.toLowerCase();
    return userTracks.filter((track) =>
      track.name.toLowerCase().includes(lowerFilter)
    );
  }, [userTracks, filter]);

  return (
    <div className="flex gap-2 overflow-x-auto pb-4">
      {/* Master track (always shown) */}
      <TrackStripWithMeter trackIndex={0} />

      {/* Filtered user tracks */}
      {filteredTracks.map((track) => (
        <TrackStripWithMeter key={track.index} trackIndex={track.index} />
      ))}

      {userTracks.length > 0 && filteredTracks.length === 0 && (
        <div className="text-gray-500 p-4">No matching tracks</div>
      )}

      {userTracks.length === 0 && (
        <div className="text-gray-500 p-4">No tracks in project</div>
      )}
    </div>
  );
}

function TrackStripWithMeter({ trackIndex }: { trackIndex: number }) {
  return (
    <div className="flex gap-1">
      <LevelMeter trackIndex={trackIndex} height={200} />
      <TrackStrip trackIndex={trackIndex} />
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

  return (
    <>
      {/* Mixer controls - separate line, left-aligned */}
      <div className="flex items-center gap-2 mb-3">
        <TrackFilter
          value={trackFilter}
          onChange={setTrackFilter}
          className="max-w-xs"
          placeholder="Filter tracks..."
        />
        <MixerLockButton />
        <UnselectAllTracksButton />
      </div>

      {/* Track list */}
      <TrackList filter={trackFilter} />
    </>
  );
}
