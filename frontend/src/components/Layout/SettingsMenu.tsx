/**
 * SettingsMenu Component
 * Hamburger menu for UI preferences (tab bar, transport visibility/position)
 *
 * Dropdown renders via portal to document.body to escape stacking contexts.
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { createPortal } from 'react-dom';
import { Menu, X, Eye, EyeOff, ArrowLeftRight, ToggleLeft, ToggleRight, ChevronRight } from 'lucide-react';
import { usePortalPosition } from '../../hooks/usePortalPosition';
import type { ViewId } from '../../viewRegistry';

export interface SettingsMenuProps {
  showTabBar: boolean;
  showPersistentTransport: boolean;
  transportPosition: 'left' | 'right';
  onToggleTabBar: () => void;
  onTogglePersistentTransport: () => void;
  onToggleTransportPosition: () => void;
  currentView: ViewId;
  showRecordingActions: boolean;
  onToggleRecordingActions: () => void;
  // Auto-update setting (PWA cache busting)
  autoUpdateEnabled: boolean;
  onToggleAutoUpdateEnabled: () => void;
  // Mixer view settings
  pinMasterTrack: boolean;
  onTogglePinMasterTrack: () => void;
  showAddTrackButton: boolean;
  onToggleShowAddTrackButton: () => void;
  // Actions view settings
  actionsAutoCollapse: boolean;
  onToggleActionsAutoCollapse: () => void;
  // Instruments view settings
  showPianoWheels: boolean;
  onToggleShowPianoWheels: () => void;
  // Audio monitoring
  audioMonitorActive: boolean;
  onToggleAudioMonitor: () => void;
  // View customization
  onOpenViewCustomization: () => void;
  // Timeline view settings
  onOpenTimelineSettings?: () => void;
  className?: string;
}

export function SettingsMenu({
  showTabBar,
  showPersistentTransport,
  transportPosition,
  onToggleTabBar,
  onTogglePersistentTransport,
  onToggleTransportPosition,
  currentView,
  showRecordingActions,
  onToggleRecordingActions,
  autoUpdateEnabled,
  onToggleAutoUpdateEnabled,
  pinMasterTrack,
  onTogglePinMasterTrack,
  showAddTrackButton,
  onToggleShowAddTrackButton,
  actionsAutoCollapse,
  onToggleActionsAutoCollapse,
  showPianoWheels,
  onToggleShowPianoWheels,
  audioMonitorActive,
  onToggleAudioMonitor,
  onOpenViewCustomization,
  onOpenTimelineSettings,
  className = '',
}: SettingsMenuProps): ReactElement {
  const [isOpen, setIsOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const { position } = usePortalPosition(triggerRef, isOpen, { placement: 'bottom-start', offset: 8 });

  // Close menu when clicking outside
  useEffect(() => {
    if (!isOpen) return;

    function handleClickOutside(event: MouseEvent) {
      const target = event.target as Node;
      const clickedTrigger = triggerRef.current?.contains(target);
      const clickedDropdown = dropdownRef.current?.contains(target);
      if (!clickedTrigger && !clickedDropdown) {
        setIsOpen(false);
      }
    }

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isOpen]);

  return (
    <div className={`relative ${className}`}>
      {/* Hamburger button */}
      <button
        ref={triggerRef}
        onClick={() => setIsOpen(!isOpen)}
        className="p-2 rounded-lg bg-bg-surface/80 hover:bg-bg-elevated transition-colors"
        title="Settings"
        aria-expanded={isOpen}
        aria-haspopup="true"
      >
        {isOpen ? <X size={20} /> : <Menu size={20} />}
      </button>

      {/* Dropdown menu - portaled to body */}
      {isOpen && createPortal(
        <div
          ref={dropdownRef}
          data-testid="settings-dropdown"
          className="fixed w-56 bg-bg-surface rounded-lg shadow-xl border border-border-subtle py-2 z-dropdown"
          style={{ top: position.top, left: position.left }}
        >
          <div className="px-3 py-1.5 text-xs text-text-secondary uppercase tracking-wide">
            Global
          </div>

          {/* Tab Bar toggle */}
          <button
            onClick={() => {
              onToggleTabBar();
            }}
            className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
            data-testid="settings-tab-bar"
          >
            <span className="text-sm">Tab Bar</span>
            <span className={`flex items-center gap-1.5 text-xs ${showTabBar ? 'text-success' : 'text-text-muted'}`}>
              {showTabBar ? <Eye size={14} /> : <EyeOff size={14} />}
              {showTabBar ? 'Visible' : 'Hidden'}
            </span>
          </button>

          {/* Persistent Transport toggle */}
          <button
            onClick={() => {
              onTogglePersistentTransport();
            }}
            className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
            data-testid="settings-transport-bar"
          >
            <span className="text-sm">Transport Bar</span>
            <span className={`flex items-center gap-1.5 text-xs ${showPersistentTransport ? 'text-success' : 'text-text-muted'}`}>
              {showPersistentTransport ? <Eye size={14} /> : <EyeOff size={14} />}
              {showPersistentTransport ? 'Visible' : 'Hidden'}
            </span>
          </button>

          {/* Transport Position toggle */}
          <button
            onClick={() => {
              onToggleTransportPosition();
            }}
            className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
            data-testid="settings-transport-position"
          >
            <span className="text-sm">Transport Position</span>
            <span className="flex items-center gap-1.5 text-xs text-primary">
              <ArrowLeftRight size={14} />
              {transportPosition === 'left' ? 'Left' : 'Right'}
            </span>
          </button>

          {/* Recording Actions toggle */}
          <button
            onClick={() => {
              onToggleRecordingActions();
            }}
            className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
            data-testid="settings-rec-quick-actions"
          >
            <span className="text-sm">Recording Actions</span>
            <span className={`flex items-center gap-1.5 text-xs ${showRecordingActions ? 'text-success' : 'text-text-muted'}`}>
              {showRecordingActions ? <Eye size={14} /> : <EyeOff size={14} />}
              {showRecordingActions ? 'Visible' : 'Hidden'}
            </span>
          </button>

          {/* Audio Monitor toggle */}
          <button
            onClick={() => {
              onToggleAudioMonitor();
            }}
            className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
            data-testid="settings-audio-monitor"
          >
            <span className="text-sm">Audio Monitor</span>
            <span className={`flex items-center gap-1.5 text-xs ${audioMonitorActive ? 'text-success' : 'text-text-muted'}`}>
              {audioMonitorActive ? <ToggleRight size={18} /> : <ToggleLeft size={18} />}
            </span>
          </button>

          {/* Auto-Update toggle */}
          <button
            onClick={() => {
              onToggleAutoUpdateEnabled();
            }}
            className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
            data-testid="settings-auto-update"
          >
            <span className="text-sm">Auto-Update</span>
            <span className={`flex items-center gap-1.5 text-xs ${autoUpdateEnabled ? 'text-success' : 'text-text-muted'}`}>
              {autoUpdateEnabled ? <ToggleRight size={18} /> : <ToggleLeft size={18} />}
            </span>
          </button>

          {/* Customize Views - opens bottom sheet */}
          <button
            onClick={() => {
              setIsOpen(false);
              onOpenViewCustomization();
            }}
            className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
          >
            <span className="text-sm">Customize Views</span>
            <ChevronRight size={16} className="text-text-muted" />
          </button>

          {/* Timeline section - only shown in Timeline view */}
          {currentView === 'timeline' && onOpenTimelineSettings && (
            <>
              <div className="my-2 border-t border-border-subtle" />

              <div className="px-3 py-1.5 text-xs text-text-secondary uppercase tracking-wide">
                Timeline
              </div>

              {/* Open Timeline Settings sheet */}
              <button
                onClick={() => {
                  setIsOpen(false);
                  onOpenTimelineSettings();
                }}
                className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
              >
                <span className="text-sm">Settings</span>
                <ChevronRight size={16} className="text-text-muted" />
              </button>
            </>
          )}

          {/* Mixer section - only shown in Mixer view */}
          {currentView === 'mixer' && (
            <>
              <div className="my-2 border-t border-border-subtle" />

              <div className="px-3 py-1.5 text-xs text-text-secondary uppercase tracking-wide">
                Mixer
              </div>

              {/* Pin Master Track toggle */}
              <button
                onClick={() => {
                  onTogglePinMasterTrack();
                }}
                className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
              >
                <span className="text-sm">Pin MASTER</span>
                <span className={`flex items-center gap-1.5 text-xs ${pinMasterTrack ? 'text-success' : 'text-text-muted'}`}>
                  {pinMasterTrack ? <ToggleRight size={18} /> : <ToggleLeft size={18} />}
                </span>
              </button>

              {/* Show Add Track Button toggle */}
              <button
                onClick={() => {
                  onToggleShowAddTrackButton();
                }}
                className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
              >
                <span className="text-sm">Add Track Button</span>
                <span className={`flex items-center gap-1.5 text-xs ${showAddTrackButton ? 'text-success' : 'text-text-muted'}`}>
                  {showAddTrackButton ? <ToggleRight size={18} /> : <ToggleLeft size={18} />}
                </span>
              </button>
            </>
          )}

          {/* Actions section - only shown in Actions view */}
          {currentView === 'actions' && (
            <>
              <div className="my-2 border-t border-border-subtle" />

              <div className="px-3 py-1.5 text-xs text-text-secondary uppercase tracking-wide">
                Actions
              </div>

              {/* Auto-collapse toggle */}
              <button
                onClick={() => {
                  onToggleActionsAutoCollapse();
                }}
                className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
              >
                <span className="text-sm">Auto-Collapse Others</span>
                <span className={`flex items-center gap-1.5 text-xs ${actionsAutoCollapse ? 'text-success' : 'text-text-muted'}`}>
                  {actionsAutoCollapse ? <ToggleRight size={18} /> : <ToggleLeft size={18} />}
                </span>
              </button>
            </>
          )}

          {/* Instruments section - only shown in Instruments view */}
          {currentView === 'instruments' && (
            <>
              <div className="my-2 border-t border-border-subtle" />

              <div className="px-3 py-1.5 text-xs text-text-secondary uppercase tracking-wide">
                Instruments
              </div>

              {/* Mod & Pitch Wheels toggle */}
              <button
                onClick={() => {
                  onToggleShowPianoWheels();
                }}
                className="w-full px-menu-item-x py-menu-item-y flex items-center justify-between hover:bg-bg-elevated/50 transition-colors"
              >
                <span className="text-sm">Mod & Pitch Wheels</span>
                <span className={`flex items-center gap-1.5 text-xs ${showPianoWheels ? 'text-success' : 'text-text-muted'}`}>
                  {showPianoWheels ? <Eye size={14} /> : <EyeOff size={14} />}
                  {showPianoWheels ? 'Visible' : 'Hidden'}
                </span>
              </button>
            </>
          )}
        </div>,
        document.body
      )}
    </div>
  );
}
