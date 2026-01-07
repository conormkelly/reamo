/**
 * MixerSection - Mixer content for Studio view
 * Renders track list with meters and controls
 * Collapse is handled by parent CollapsibleSection wrapper
 */

import { useState, useMemo, type ReactElement } from 'react';
import { Lock, Unlock, XCircle } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTracks, useTrackSubscription, useTrackSkeleton, type TrackSubscription } from '../../hooks';
// Note: useTracks is still used by UnselectAllTracksButton below
import { track as trackCmd } from '../../core/WebSocketCommands';
import { TrackStrip, LevelMeter, TrackFilter } from '../Track';

function TrackList({ filter }: { filter: string }) {
  const { sendCommand } = useReaper();
  const tracks = useReaperStore((state) => state.tracks);
  const { totalTracks, filterByName } = useTrackSkeleton();

  // Filter using skeleton (has ALL tracks) - returns tracks with their indices
  const filteredSkeleton = useMemo(() => {
    return filterByName(filter);
  }, [filterByName, filter]);

  // Build subscription based on filter state
  const subscription: TrackSubscription = useMemo(() => {
    if (!filter.trim()) {
      // No filter: subscribe to range of all tracks
      return {
        mode: 'range',
        start: 1, // Start at 1 (user tracks), master handled separately
        end: Math.max(totalTracks, 1),
      };
    } else {
      // Filter active: subscribe to specific GUIDs (excluding master - handled by includeMaster)
      const userGuids = filteredSkeleton
        .filter((t) => t.g !== 'master')
        .map((t) => t.g);
      return {
        mode: 'guids',
        guids: userGuids,
      };
    }
  }, [filter, totalTracks, filteredSkeleton]);

  // Subscribe to track updates (data + meters)
  useTrackSubscription(subscription, {
    sendCommand,
    includeMaster: true, // Always include master track
  });

  // Get indices to render (from skeleton when filtered, or from store when not)
  const trackIndicesToRender = useMemo(() => {
    if (!filter.trim()) {
      // No filter: render all tracks we have data for (excluding master)
      return Object.keys(tracks)
        .map(Number)
        .filter((idx) => idx > 0)
        .sort((a, b) => a - b);
    } else {
      // Filter active: render filtered tracks that we have data for
      return filteredSkeleton
        .filter((t) => t.g !== 'master' && tracks[t.index])
        .map((t) => t.index);
    }
  }, [filter, filteredSkeleton, tracks]);

  const hasUserTracks = totalTracks > 0 || Object.keys(tracks).length > 1;

  return (
    <div className="flex gap-2 overflow-x-auto pb-4">
      {/* Master track (always shown) */}
      <TrackStripWithMeter trackIndex={0} />

      {/* Filtered user tracks */}
      {trackIndicesToRender.map((idx) => (
        <TrackStripWithMeter key={idx} trackIndex={idx} />
      ))}

      {hasUserTracks && trackIndicesToRender.length === 0 && filter.trim() && (
        <div className="text-gray-500 p-4">No matching tracks</div>
      )}

      {!hasUserTracks && (
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
