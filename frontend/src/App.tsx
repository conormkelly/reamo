/**
 * REAmo - REAPER Web Control
 * Main application with view switching
 */

import { useState, useEffect, useMemo } from 'react';
import './index.css';
import {
  ReaperProvider,
  useReaper,
  TabBar,
  PersistentTransport,
  ConnectionBanner,
  UpdateBanner,
  MemoryWarningBar,
  RecordingActionsBar,
  ErrorBoundary,
  ModalRoot,
  ToastRoot,
  SideRail,
  ContextRail,
  type ContextRailTabConfig,
} from './components';
import { Info } from 'lucide-react';
import { useUIPreferences, useTransport, useLayoutContext } from './hooks';
import { useReaperStore } from './store';
import { views, type ViewId, VIEW_STORAGE_KEY, DEFAULT_VIEW } from './viewRegistry';
import { NAV_RAIL_WIDTH, CONTEXT_RAIL_WIDTH } from './constants/layout';

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
  const updateAvailable = useReaperStore((s) => s.updateAvailable);
  const { isRecording } = useTransport();

  // Layout context for responsive side rail
  const { navPosition } = useLayoutContext();
  const useSideRail = navPosition === 'side';

  // Calculate bottom offset for RecordingActionsBar (above tab bar + transport)
  // In side rail mode, bottom chrome is moved to side, so offset is 0
  const TAB_BAR_HEIGHT = 48;
  const PERSISTENT_TRANSPORT_HEIGHT = 56;
  const bottomOffset = useSideRail
    ? 0
    : (showTabBar ? TAB_BAR_HEIGHT : 0) + (showPersistentTransport ? PERSISTENT_TRANSPORT_HEIGHT : 0);

  // Persist view selection
  useEffect(() => {
    try {
      localStorage.setItem(VIEW_STORAGE_KEY, currentView);
    } catch {
      // Ignore quota exceeded errors on iOS
    }
  }, [currentView]);

  const ViewComponent = views[currentView];

  // Get context rail state from store (populated by views)
  const sideRailBankNav = useReaperStore((s) => s.sideRailBankNav);
  const sideRailBankNavCallbacks = useReaperStore((s) => s.sideRailBankNavCallbacks);
  const sideRailInfo = useReaperStore((s) => s.sideRailInfo);

  // Build context rail tabs from store state
  const contextRailTabs: ContextRailTabConfig[] = useMemo(() => {
    const tabs: ContextRailTabConfig[] = [];

    // Info tab (always present for mixer/timeline)
    if (sideRailInfo) {
      tabs.push({
        id: 'info',
        icon: Info,
        label: sideRailInfo.label,
        content: sideRailInfo.content,
      });
    }

    // Toolbar tab (only for timeline - identified by label containing "Toolbar")
    if (sideRailInfo?.label.includes('Toolbar')) {
      // Timeline provides combined content, so info tab already has toolbar
      // No separate toolbar tab needed - it's included in the combined content
    }

    return tabs;
  }, [sideRailInfo]);

  // Build context rail bank nav props from store
  const contextRailBankNav = useMemo(() => {
    if (!sideRailBankNav) return null;
    return {
      bankDisplay: sideRailBankNav.bankDisplay,
      canGoBack: sideRailBankNav.canGoBack,
      canGoForward: sideRailBankNav.canGoForward,
      onBack: sideRailBankNavCallbacks.onBack ?? (() => {}),
      onForward: sideRailBankNavCallbacks.onForward ?? (() => {}),
    };
  }, [sideRailBankNav, sideRailBankNavCallbacks]);

  // Check if current view supports context rail (has bank nav)
  const showContextRail = useSideRail && (currentView === 'mixer' || currentView === 'timeline');

  // Dual-rail mode: horizontal layout with NavRail on left, ContextRail on right
  if (useSideRail) {
    return (
      <div className="flex flex-row h-dvh bg-bg-app overflow-hidden select-none isolate">
        {/* Nav Rail (left) - view tabs + transport */}
        <SideRail
          currentView={currentView}
          onViewChange={setCurrentView}
          className="z-fixed"
        />

        {/* Main content column */}
        <div className="flex flex-col flex-1 min-w-0 safe-area-top">
          {/* Conditional banners */}
          <ConnectionBanner className="shrink-0" />
          {updateAvailable && <UpdateBanner className="shrink-0" />}
          <MemoryWarningBar className="shrink-0" />

          {/* Main content area */}
          <main className="flex-1 min-h-0 overflow-hidden">
            <ErrorBoundary>
              <ViewComponent />
            </ErrorBoundary>
          </main>

          {/* Recording Actions Bar - positioned between the two rails */}
          {showRecordingActions && isRecording && (
            <div
              className="fixed z-[310] bg-bg-app pb-3"
              style={{
                // Account for safe areas: rail content width + safe area inset
                left: `calc(${NAV_RAIL_WIDTH}px + env(safe-area-inset-left, 0px))`,
                right: showContextRail ? `calc(${CONTEXT_RAIL_WIDTH}px + env(safe-area-inset-right, 0px))` : '0px',
                bottom: 'env(safe-area-inset-bottom, 0px)',
              }}
            >
              <RecordingActionsBar />
            </div>
          )}
        </div>

        {/* Context Rail (right) - tabs, bank nav, search */}
        {showContextRail && contextRailTabs.length > 0 && (
          <ContextRail
            tabs={contextRailTabs}
            bankNav={contextRailBankNav}
            search={null} // TODO: Wire up search from views
            className="z-fixed"
          />
        )}

        {/* Centralized modal rendering */}
        <ModalRoot />
        <ToastRoot />
      </div>
    );
  }

  // Bottom navigation mode: standard vertical layout (default)
  return (
    <div className="flex flex-col h-dvh bg-bg-app overflow-hidden safe-area-top safe-area-x select-none isolate">
      {/* Conditional banners - shrink-0 prevents compression */}
      <ConnectionBanner className="shrink-0" />
      {updateAvailable && <UpdateBanner className="shrink-0" />}
      <MemoryWarningBar className="shrink-0" />

      {/* Main content area - THE CRITICAL PATTERN: flex-1 min-h-0 */}
      <main className="flex-1 min-h-0 overflow-hidden">
        <ErrorBoundary>
          <ViewComponent />
        </ErrorBoundary>
      </main>

      {/* Recording Actions Bar - z-[310] is above other fixed chrome (z-fixed=300) */}
      {showRecordingActions && isRecording && (
        <div
          className="fixed left-0 right-0 z-[310] bg-bg-app pb-3"
          style={{ bottom: `calc(${bottomOffset}px + env(safe-area-inset-bottom, 34px))` }}
        >
          <RecordingActionsBar />
        </div>
      )}

      {/* Fixed footer chrome - z-fixed (300) */}
      {showTabBar && (
        <TabBar
          currentView={currentView}
          onViewChange={setCurrentView}
          className={`shrink-0 z-fixed ${!showPersistentTransport ? 'safe-area-bottom' : ''}`}
        />
      )}
      {showPersistentTransport && (
        <PersistentTransport position={transportPosition} className="shrink-0 z-fixed safe-area-bottom" />
      )}

      {/* Centralized modal rendering */}
      <ModalRoot />
      <ToastRoot />
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
    <div className="flex flex-col items-center justify-center h-dvh gap-6 bg-bg-app px-6 text-center">
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

  // Load persisted UI preferences from localStorage on startup
  // Note: View filters and timeline state are session-scoped (not persisted)
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
