/**
 * Reamo - REAPER Web Control
 * Main application with view switching
 */

import { useState, useEffect } from 'react';
import './index.css';
import { ReaperProvider, TabBar, PersistentTransport, SettingsMenu, ConnectionBanner } from './components';
import { useUIPreferences } from './hooks';
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

  // Persist view selection
  useEffect(() => {
    localStorage.setItem(VIEW_STORAGE_KEY, currentView);
  }, [currentView]);

  const ViewComponent = views[currentView];

  return (
    <div className="flex flex-col h-screen bg-gray-950">
      {/* Connection banner - shown at top when disconnected */}
      <ConnectionBanner />

      {/* Settings menu - floating top-left */}
      <div className="absolute top-3 left-3 z-50">
        <SettingsMenu
          showTabBar={showTabBar}
          showPersistentTransport={showPersistentTransport}
          transportPosition={transportPosition}
          onToggleTabBar={toggleTabBar}
          onTogglePersistentTransport={togglePersistentTransport}
          onToggleTransportPosition={toggleTransportPosition}
        />
      </div>

      {/* Active view area - fills available space, min-h-0 allows flex shrinking */}
      <main className="flex-1 min-h-0 overflow-auto">
        <ViewComponent />
      </main>

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
