/**
 * REAmo - REAPER Web Control
 * Main application with view switching
 */

import { useState, useEffect } from 'react';
import './index.css';
import {
  ReaperProvider,
  useReaper,
  TabBar,
  PersistentTransport,
  ConnectionBanner,
  MemoryWarningBar,
  RecordingActionsBar,
  ErrorBoundary,
} from './components';
import { useUIPreferences, useTransport } from './hooks';
import { useReaperStore } from './store';
import { views, type ViewId, VIEW_STORAGE_KEY, DEFAULT_VIEW } from './viewRegistry';

function AppContent() {
  // DEV FAILSAFE: Uncomment to clear all localStorage on init (useful when API changes break stored data)
  // localStorage.clear(); console.warn('DEV: localStorage cleared');

  const [currentView, setCurrentView] = useState<ViewId>(() => {
    try {
      const saved = localStorage.getItem(VIEW_STORAGE_KEY) as ViewId | null;
      return saved && saved in views ? saved : DEFAULT_VIEW;
    } catch {
      return DEFAULT_VIEW;
    }
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
    try {
      localStorage.setItem(VIEW_STORAGE_KEY, currentView);
    } catch {
      // Ignore quota exceeded errors on iOS
    }
  }, [currentView]);

  const ViewComponent = views[currentView];

  return (
    <div className="flex flex-col h-screen-safe bg-bg-app overflow-hidden safe-area-top safe-area-x">
      {/* Connection banner - shown at top when disconnected */}
      <ConnectionBanner />

      {/* Memory warning bar - shown when arena utilization is high */}
      <MemoryWarningBar />

      {/* Active view area - each view renders its own header via ViewHeader */}
      <main className="flex-1 min-h-0 overflow-auto">
        <ErrorBoundary>
          <ViewComponent />
        </ErrorBoundary>
      </main>

      {/* Recording Actions Bar - only in Studio view when recording */}
      {currentView === 'studio' && showRecordingActions && isRecording && isMobile && (
        <div
          className="fixed left-0 right-0 z-40 bg-bg-app pb-3"
          style={{ bottom: `calc(${mobileBottomOffset}px + env(safe-area-inset-bottom, 34px))` }}
        >
          <RecordingActionsBar />
        </div>
      )}

      {/* Tab bar - toggleable, gets safe-area-bottom when it's the bottommost element */}
      {showTabBar && (
        <TabBar
          currentView={currentView}
          onViewChange={setCurrentView}
          className={!showPersistentTransport ? 'safe-area-bottom' : ''}
        />
      )}

      {/* Persistent transport - toggleable with position, always bottommost when shown */}
      {showPersistentTransport && (
        <PersistentTransport position={transportPosition} className="safe-area-bottom" />
      )}
    </div>
  );
}

/**
 * Loading screen - shown while connecting to REAPER
 */
function LoadingScreen() {
  const { gaveUp } = useReaper();
  const [elapsed, setElapsed] = useState(0);

  // Count elapsed seconds
  useEffect(() => {
    const timer = setInterval(() => {
      setElapsed(s => s + 1);
    }, 1000);
    return () => clearInterval(timer);
  }, []);

  const troubleState = elapsed >= 10 || gaveUp;

  return (
    <div className="flex flex-col items-center justify-center h-screen-safe gap-6 bg-bg-app px-6 text-center">
      {/* REAmo heading */}
      <h1 className="text-2xl font-semibold tracking-wide text-text-primary">REAmo</h1>

      {/* Phone/remote icon with rotating Venn diagram circles */}
      <svg className="w-32 h-32" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 80">
        <rect x="0" y="0" width="48" height="80" rx="14" fill="#3a3a3a"/>
        <g>
          {!troubleState && (
            <animateTransform
              attributeName="transform"
              type="rotate"
              from="0 24 41"
              to="360 24 41"
              dur="4s"
              repeatCount="indefinite"
            />
          )}
          <circle cx="24" cy="32" r="12" fill="#5ba3d4" opacity="0.9"/>
          <circle cx="16" cy="46" r="12" fill="#7ec96b" opacity="0.9"/>
          <circle cx="32" cy="46" r="12" fill="#d4956b" opacity="0.9"/>
        </g>
      </svg>

      {troubleState ? (
        /* Trouble connecting state */
        <div className="flex flex-col items-center gap-4 max-w-xs">
          <p className="text-text-secondary text-sm">
            Having trouble connecting to REAPER.
          </p>
          <button
            onClick={() => window.location.reload()}
            className="px-4 py-2 bg-primary hover:bg-primary-hover text-text-on-primary text-sm font-medium rounded-lg transition-colors"
          >
            Retry
          </button>
        </div>
      ) : elapsed >= 1 ? (
        <p className="text-text-secondary text-sm">Connecting...</p>
      ) : null}
    </div>
  );
}

// Minimum time to show loading screen (prevents jarring flash on fast connections)
const MIN_LOADING_MS = 750;

/**
 * App wrapper that shows loading screen until connected
 */
function AppWithLoading() {
  const { connected } = useReaper();
  const [minTimePassed, setMinTimePassed] = useState(false);
  const loadUIPrefsFromStorage = useReaperStore((s) => s.loadUIPrefsFromStorage);

  // Load UI preferences from localStorage on startup
  useEffect(() => {
    loadUIPrefsFromStorage();
  }, [loadUIPrefsFromStorage]);

  useEffect(() => {
    const timer = setTimeout(() => setMinTimePassed(true), MIN_LOADING_MS);
    return () => clearTimeout(timer);
  }, []);

  // Show loading screen until connected AND minimum time has passed
  if (!connected || !minTimePassed) {
    return <LoadingScreen />;
  }

  return <AppContent />;
}

function App() {
  return (
    <ReaperProvider autoStart={true}>
      <AppWithLoading />
    </ReaperProvider>
  );
}

export default App;
