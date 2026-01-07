/**
 * Reamo - REAPER Web Control
 * Main application with view switching
 */

import { useState, useEffect } from 'react';
import './index.css';
import {
  ReaperProvider,
  TabBar,
  PersistentTransport,
  ConnectionBanner,
  MemoryWarningBar,
  RecordingActionsBar,
} from './components';
import { useUIPreferences, useTransport } from './hooks';
import { useReaperStore } from './store';
import { views, type ViewId, VIEW_STORAGE_KEY, DEFAULT_VIEW } from './viewRegistry';

function AppContent() {
  const [currentView, setCurrentView] = useState<ViewId>(() => {
    const saved = localStorage.getItem(VIEW_STORAGE_KEY) as ViewId | null;
    return saved && saved in views ? saved : DEFAULT_VIEW;
  });

  const { showTabBar, showPersistentTransport, transportPosition } = useUIPreferences();
  const showRecordingActions = useReaperStore((s) => s.showRecordingActions);
  const { isRecording } = useTransport();

  // Detect mobile for RecordingActionsBar positioning
  const [isMobile, setIsMobile] = useState(() => window.innerWidth <= 768);

  useEffect(() => {
    const handleResize = () => setIsMobile(window.innerWidth <= 768);
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  // Calculate bottom offset for mobile RecordingActionsBar
  const TAB_BAR_HEIGHT = 48;
  const PERSISTENT_TRANSPORT_HEIGHT = 56;
  const mobileBottomOffset =
    (showTabBar ? TAB_BAR_HEIGHT : 0) +
    (showPersistentTransport ? PERSISTENT_TRANSPORT_HEIGHT : 0);

  // Persist view selection
  useEffect(() => {
    localStorage.setItem(VIEW_STORAGE_KEY, currentView);
  }, [currentView]);

  const ViewComponent = views[currentView];

  return (
    <div className="flex flex-col h-screen bg-gray-950 overflow-hidden">
      {/* Connection banner - shown at top when disconnected */}
      <ConnectionBanner />

      {/* Memory warning bar - shown when arena utilization is high */}
      <MemoryWarningBar />

      {/* Active view area - each view renders its own header via ViewHeader */}
      <main className="flex-1 min-h-0 overflow-auto">
        <ViewComponent />
      </main>

      {/* Recording Actions Bar - only in Studio view when recording */}
      {currentView === 'studio' && showRecordingActions && isRecording && isMobile && (
        <div
          className="fixed left-0 right-0 z-40 bg-gray-950 pb-3"
          style={{ bottom: `${mobileBottomOffset}px` }}
        >
          <RecordingActionsBar />
        </div>
      )}

      {/* Tab bar - toggleable */}
      {showTabBar && (
        <TabBar currentView={currentView} onViewChange={setCurrentView} />
      )}

      {/* Persistent transport - toggleable with position */}
      {showPersistentTransport && (
        <PersistentTransport position={transportPosition} />
      )}
    </div>
  );
}

function App() {
  return (
    <ReaperProvider autoStart={true}>
      <AppContent />
    </ReaperProvider>
  );
}

export default App;
