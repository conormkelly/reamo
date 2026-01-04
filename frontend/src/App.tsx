/**
 * Reamo - REAPER Web Control
 * Main application with view switching
 */

import { useState, useEffect } from 'react';
import './index.css';
import { ReaperProvider, TabBar, PersistentTransport, SettingsMenu, ConnectionBanner, RecordingActionsBar } from './components';
import { useUIPreferences } from './hooks';
import { useReaperStore } from './store';
import { views, type ViewId, VIEW_STORAGE_KEY, DEFAULT_VIEW } from './viewRegistry';

function AppContent() {
  const [currentView, setCurrentView] = useState<ViewId>(() => {
    const saved = localStorage.getItem(VIEW_STORAGE_KEY) as ViewId | null;
    return saved && saved in views ? saved : DEFAULT_VIEW;
  });

  const {
    showTabBar,
    showPersistentTransport,
    transportPosition,
    toggleTabBar,
    togglePersistentTransport,
    toggleTransportPosition,
  } = useUIPreferences();

  const showRecordingActions = useReaperStore((s) => s.showRecordingActions);
  const setShowRecordingActions = useReaperStore((s) => s.setShowRecordingActions);
  const actionsAutoCollapse = useReaperStore((s) => s.actionsAutoCollapse);
  const setActionsAutoCollapse = useReaperStore((s) => s.setActionsAutoCollapse);

  // Detect mobile for RecordingActionsBar positioning
  const [isMobile, setIsMobile] = useState(() => window.innerWidth <= 768);

  useEffect(() => {
    const handleResize = () => setIsMobile(window.innerWidth <= 768);
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  // Calculate bottom offset for mobile RecordingActionsBar
  // Tab bar height: ~48px, Persistent transport height: ~56px
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
    <div className="flex flex-col h-screen bg-gray-950">
      {/* Connection banner - shown at top when disconnected */}
      <ConnectionBanner />

      {/* Header controls - floating top-left */}
      <div className="absolute top-3 left-3 z-50">
        <SettingsMenu
          showTabBar={showTabBar}
          showPersistentTransport={showPersistentTransport}
          transportPosition={transportPosition}
          onToggleTabBar={toggleTabBar}
          onTogglePersistentTransport={togglePersistentTransport}
          onToggleTransportPosition={toggleTransportPosition}
          currentView={currentView}
          showRecordingActions={showRecordingActions}
          onToggleRecordingActions={() => setShowRecordingActions(!showRecordingActions)}
          actionsAutoCollapse={actionsAutoCollapse}
          onToggleActionsAutoCollapse={() => setActionsAutoCollapse(!actionsAutoCollapse)}
        />
      </div>

      {/* Active view area - fills available space, min-h-0 allows flex shrinking */}
      <main className="flex-1 min-h-0 overflow-auto">
        <ViewComponent />
      </main>

      {/* Recording Actions Bar - only in Studio view */}
      {currentView === 'studio' && showRecordingActions && (
        isMobile ? (
          // Mobile: Fixed positioning above bottom nav bars
          <div
            className="fixed left-0 right-0 z-40 bg-gray-950 pb-3"
            style={{ bottom: `${mobileBottomOffset}px` }}
          >
            <RecordingActionsBar />
          </div>
        ) : (
          // Desktop/tablet: Normal document flow (rendered in StudioView would be better, but this works)
          // Actually, for desktop we should render it within StudioView for proper flow
          // For now, skip desktop rendering here since StudioView should handle it
          null
        )
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
