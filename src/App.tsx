/**
 * Reactper - Hello World Demo
 * A simple REAPER control surface
 */

import { useState, useMemo } from 'react';
import './index.css';
import {
  ReaperProvider,
  ConnectionStatus,
  TransportBar,
  TimeDisplay,
  TrackStrip,
  LevelMeter,
  TrackFilter,
  MetronomeButton,
  UndoButton,
  RedoButton,
  SaveButton,
  AddMarkerButton,
  PrevMarkerButton,
  NextMarkerButton,
  TapTempoButton,
  Timeline,
  TakeSwitcher,
} from './components';
import { useTracks, useTimeSelectionSync } from './hooks';

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

function AppContent() {
  const [trackFilter, setTrackFilter] = useState('');

  // Sync REAPER's time selection on init
  const { isSyncing } = useTimeSelectionSync();

  return (
    <div className="min-h-screen bg-gray-950 text-white p-4">
      {/* Header: Connection + Tempo right */}
      <header className="flex items-center justify-end mb-4">
        <div className="flex items-center gap-3">
          <MetronomeButton />
          <TapTempoButton />
          <ConnectionStatus />
        </div>
      </header>

      {/* Time Display - centered above transport */}
      <section className="flex justify-center mb-4">
        <TimeDisplay format="both" isSyncing={isSyncing} />
      </section>

      {/* Transport Controls */}
      <section className="mb-6">
        <TransportBar className="mb-3" />
        <div className="flex flex-wrap items-center justify-center gap-2">
          <UndoButton />
          <RedoButton />
          <SaveButton />
        </div>
      </section>

      {/* Timeline */}
      <section className="mb-4">
        <Timeline height={80} isSyncing={isSyncing} />
      </section>

      {/* Marker Navigation - centered below timeline */}
      <section className="flex justify-center items-center gap-2 mb-6">
        <PrevMarkerButton />
        <NextMarkerButton />
        <AddMarkerButton />
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

      {/* Take Switcher - below mixer */}
      <section className="mt-4">
        <TakeSwitcher />
      </section>

      {/* Footer */}
      <footer className="mt-8 text-center text-gray-600 text-sm">
        REAPER Web Control • Built with React + Zustand
      </footer>
    </div>
  );
}

function App() {
  return (
    <ReaperProvider autoStart={true} transportInterval={30} trackInterval={200}>
      <AppContent />
    </ReaperProvider>
  );
}

export default App;
