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
} from './components';
import { useTracks } from './hooks';

function TrackList() {
  const { userTracks } = useTracks();

  return (
    <div className="flex gap-2 overflow-x-auto pb-4">
      {/* Master track */}
      <TrackStrip trackIndex={0} />

      {/* User tracks */}
      {userTracks.map((track) => (
        <TrackStrip key={track.index} trackIndex={track.index} />
      ))}

      {userTracks.length === 0 && (
        <div className="text-gray-500 p-4">No tracks in project</div>
      )}
    </div>
  );
}

function App() {
  return (
    <ReaperProvider autoStart={true} transportInterval={30} trackInterval={500}>
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
          </div>
          <TimeDisplay format="both" showState />
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
