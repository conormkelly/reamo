/**
 * Reactper - Hello World Demo
 * A simple REAPER control surface
 */

import { useState, useMemo } from 'react';
import { RectangleHorizontal } from 'lucide-react';
import './index.css';
import {
  ReaperProvider,
  ConnectionStatus,
  TransportBar,
  TimeDisplay,
  RecordingActionsBar,
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
  TimeSignatureButton,
  Timeline,
  TimelineModeToggle,
  RegionEditActionBar,
  RegionInfoBar,
  AddRegionModal,
  MakeSelectionModal,
  TakeSwitcher,
  MarkerInfoBar,
} from './components';
import { useTracks, useTimeSelectionSync, useRegionEditScriptDetection, useMarkerEditScriptDetection } from './hooks';
import { useReaperStore } from './store';

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
  const [showAddRegionModal, setShowAddRegionModal] = useState(false);
  const [showMakeSelectionModal, setShowMakeSelectionModal] = useState(false);
  const timelineMode = useReaperStore((s) => s.timelineMode);

  // Sync REAPER's time selection on init
  const { isSyncing } = useTimeSelectionSync();

  // Detect if the region editing Lua script is installed
  useRegionEditScriptDetection();

  // Detect if the marker editing Lua script is installed
  useMarkerEditScriptDetection();

  return (
    <div className="min-h-screen bg-gray-950 text-white p-4">
      {/* Header: Connection + Tempo right */}
      <header className="flex items-center justify-end mb-4">
        <div className="flex items-center gap-3">
          <MetronomeButton />
          <TapTempoButton />
          <TimeSignatureButton />
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

      {/* Recording Quick Actions - visible during recording */}
      <RecordingActionsBar className="mb-6" />

      {/* Timeline */}
      <section className="mb-4">
        <div className="flex items-center justify-between mb-2">
          <h3 className="text-sm font-medium text-gray-400">Timeline</h3>
          <TimelineModeToggle />
        </div>
        <Timeline height={80} isSyncing={isSyncing} />
        <RegionInfoBar
          className="mt-2"
          onAddRegion={timelineMode === 'regions' ? () => setShowAddRegionModal(true) : undefined}
        />
        <div className="mt-2">
          <RegionEditActionBar />
        </div>
      </section>

      {/* Marker Info & Navigation - hidden in regions mode */}
      {timelineMode === 'navigate' && (
        <section className="mb-6 flex flex-col sm:flex-row sm:items-center gap-3">
          {/* Marker Info Bar - shows current marker with editing */}
          <MarkerInfoBar className="flex-1" />

          {/* Navigation buttons */}
          <div className="flex items-center gap-2 flex-shrink-0">
            <button
              onClick={() => setShowMakeSelectionModal(true)}
              title="Set time selection"
              className="px-3 py-2 bg-gray-700 text-white hover:bg-gray-600 active:bg-gray-500 rounded font-medium transition-colors flex items-center"
            >
              <RectangleHorizontal size={16} className="mr-1" />
              <span>Selection</span>
            </button>
            <PrevMarkerButton />
            <NextMarkerButton />
            <AddMarkerButton />
          </div>
        </section>
      )}

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
        REAmo - REAPER Web Control
      </footer>

      {/* Add Region Modal */}
      <AddRegionModal
        isOpen={showAddRegionModal}
        onClose={() => setShowAddRegionModal(false)}
      />

      {/* Make Selection Modal */}
      <MakeSelectionModal
        isOpen={showMakeSelectionModal}
        onClose={() => setShowMakeSelectionModal(false)}
      />
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
