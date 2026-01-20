/**
 * ViewHeader Component
 * Unified header for all views: Burger menu (left) | View-specific controls (center) | Connection status (right)
 * Scrolls with content, no wasted vertical space.
 */

import type { ReactElement, ReactNode } from 'react';
import { SettingsMenu } from './SettingsMenu';
import { ConnectionStatus } from './ConnectionStatus';
import { useUIPreferences } from '../hooks';
import { useReaperStore } from '../store';
import type { ViewId } from '../viewRegistry';

export interface ViewHeaderProps {
  /** Current view ID */
  currentView: ViewId;
  /** View-specific controls to render in the center/right area */
  children?: ReactNode;
}

export function ViewHeader({ currentView, children }: ViewHeaderProps): ReactElement {
  const {
    showTabBar,
    showPersistentTransport,
    transportPosition,
    toggleTabBar,
    togglePersistentTransport,
    toggleTransportPosition,
  } = useUIPreferences();

  const autoUpdateEnabled = useReaperStore((s) => s.autoUpdateEnabled);
  const toggleAutoUpdateEnabled = useReaperStore((s) => s.toggleAutoUpdateEnabled);
  const showRecordingActions = useReaperStore((s) => s.showRecordingActions);
  const setShowRecordingActions = useReaperStore((s) => s.setShowRecordingActions);
  const pinMasterTrack = useReaperStore((s) => s.pinMasterTrack);
  const setPinMasterTrack = useReaperStore((s) => s.setPinMasterTrack);
  const showAddTrackButton = useReaperStore((s) => s.showAddTrackButton);
  const setShowAddTrackButton = useReaperStore((s) => s.setShowAddTrackButton);
  const actionsAutoCollapse = useReaperStore((s) => s.actionsAutoCollapse);
  const setActionsAutoCollapse = useReaperStore((s) => s.setActionsAutoCollapse);

  return (
    <div className="flex items-center gap-3 mb-3 min-h-[40px]">
      {/* Burger menu - left */}
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
        autoUpdateEnabled={autoUpdateEnabled}
        onToggleAutoUpdateEnabled={toggleAutoUpdateEnabled}
        pinMasterTrack={pinMasterTrack}
        onTogglePinMasterTrack={() => setPinMasterTrack(!pinMasterTrack)}
        showAddTrackButton={showAddTrackButton}
        onToggleShowAddTrackButton={() => setShowAddTrackButton(!showAddTrackButton)}
        actionsAutoCollapse={actionsAutoCollapse}
        onToggleActionsAutoCollapse={() => setActionsAutoCollapse(!actionsAutoCollapse)}
      />

      {/* View-specific controls - fills remaining space, children control their own layout */}
      <div className="flex-1 flex items-center">
        {children}
      </div>

      {/* Connection status - far right */}
      <ConnectionStatus />
    </div>
  );
}
