/**
 * Reactper - Hello World Demo
 * A simple REAPER control surface
 */

import { useState, useMemo } from 'react';
import './index.css';
import { VolumeX, Volume2, SkipBack } from 'lucide-react';
import {
  ReaperProvider,
  ConnectionStatus,
  PlayButton,
  StopButton,
  RecordButton,
  TimeDisplay,
  TrackStrip,
  LevelMeter,
  TrackFilter,
  MarkerNavigation,
  RegionNavigation,
  RegionDisplay,
  MetronomeButton,
  UndoButton,
  RedoButton,
  SaveButton,
  ActionButton,
  TapTempoButton,
  RepeatButton,
} from './components';
import { useTracks } from './hooks';

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

function App() {
  const [trackFilter, setTrackFilter] = useState('');

  return (
    <ReaperProvider autoStart={true} transportInterval={30} trackInterval={200}>
      <div className="min-h-screen bg-gray-950 text-white p-4">
        {/* Connection status - top right */}
        <div className="absolute top-4 right-4">
          <ConnectionStatus />
        </div>

        {/* Time Display - centered at top */}
        <section className="text-center mb-4">
          <TimeDisplay format="both" showState className="inline-block" />
        </section>

        {/* Current Region */}
        <section className="flex justify-center mb-4">
          <RegionDisplay />
        </section>

        {/* Transport Controls */}
        <section className="mb-6">
          <div className="flex flex-wrap items-center justify-center gap-3 mb-3">
            <PlayButton />
            <StopButton />
            <RecordButton />
            <div className="w-px h-8 bg-gray-700" />
            <MarkerNavigation showLabels={false} />
            <RegionNavigation showLabels={false} />
            <div className="w-px h-8 bg-gray-700" />
            <RepeatButton />
            <TapTempoButton />
          </div>
          <div className="flex flex-wrap items-center justify-center gap-2">
            <ActionButton actionId={40042} title="Go to Start of Project">
              <SkipBack size={16} className="inline-block mr-1" />
              Start
            </ActionButton>
            <MetronomeButton />
            <UndoButton />
            <RedoButton />
            <SaveButton />
            <ActionButton actionId={40340} title="Unsolo All Tracks">
              <VolumeX size={16} className="inline-block mr-1" />
              Unsolo All
            </ActionButton>
            <ActionButton actionId={40339} title="Unmute All Tracks">
              <Volume2 size={16} className="inline-block mr-1" />
              Unmute All
            </ActionButton>
          </div>
        </section>

        {/* Tracks */}
        <section>
          <TrackFilter
            value={trackFilter}
            onChange={setTrackFilter}
            className="mb-3 max-w-xs"
            placeholder="Filter tracks..."
          />
          <TrackList filter={trackFilter} />
        </section>

        {/* Footer */}
        <footer className="mt-8 text-center text-gray-600 text-sm">
          REAPER Web Control • Built with React + Zustand
        </footer>
      </div>
    </ReaperProvider>
  );
}

export default App;
