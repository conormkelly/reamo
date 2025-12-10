/**
 * Reactper - Hello World Demo
 * A simple REAPER control surface
 */

import './index.css';
import {
  ReaperProvider,
  ConnectionStatus,
  PlayButton,
  StopButton,
  RecordButton,
  TimeDisplay,
  TrackStrip,
  LevelMeter,
  MarkerNavigation,
  MetronomeButton,
  UndoButton,
  RedoButton,
  SaveButton,
  ActionButton,
  TapTempoButton,
  RepeatButton,
} from './components';
import { useTracks } from './hooks';

function TrackList() {
  const { userTracks } = useTracks();

  return (
    <div className="flex gap-2 overflow-x-auto pb-4">
      {/* Master track */}
      <TrackStripWithMeter trackIndex={0} />

      {/* User tracks */}
      {userTracks.map((track) => (
        <TrackStripWithMeter key={track.index} trackIndex={track.index} />
      ))}

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
  return (
    <ReaperProvider autoStart={true} transportInterval={30} trackInterval={200}>
      <div className="min-h-screen bg-gray-950 text-white p-4">
        {/* Header */}
        <header className="flex items-center justify-between mb-6">
          <h1 className="text-xl font-bold">Reactper</h1>
          <ConnectionStatus />
        </header>

        {/* Transport */}
        <section className="mb-6">
          <div className="flex items-center gap-4 mb-4">
            <PlayButton />
            <StopButton />
            <RecordButton />
            <div className="w-px h-8 bg-gray-700" />
            <MarkerNavigation showLabels={false} />
            <div className="w-px h-8 bg-gray-700" />
            <RepeatButton />
            <TapTempoButton />
          </div>
          <TimeDisplay format="both" showState />
        </section>

        {/* Quick Actions */}
        <section className="mb-6">
          <h2 className="text-lg font-semibold mb-3">Quick Actions</h2>
          <div className="flex flex-wrap gap-2">
            <MetronomeButton />
            <UndoButton />
            <RedoButton />
            <SaveButton />
            <ActionButton actionId={40340} title="Unsolo All Tracks">
              🔇 Unsolo All
            </ActionButton>
            <ActionButton actionId={40339} title="Unmute All Tracks">
              🔊 Unmute All
            </ActionButton>
          </div>
        </section>

        {/* Tracks */}
        <section>
          <h2 className="text-lg font-semibold mb-3">Tracks</h2>
          <TrackList />
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
