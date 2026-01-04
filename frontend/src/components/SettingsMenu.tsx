/**
 * SettingsMenu Component
 * Hamburger menu for UI preferences (tab bar, transport visibility/position)
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { Menu, X, Eye, EyeOff, ArrowLeftRight } from 'lucide-react';
import type { ViewId } from '../viewRegistry';
import { ReorderSectionsModal } from './Studio';

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
  // Actions view settings
  actionsAutoCollapse: boolean;
  onToggleActionsAutoCollapse: () => void;
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
  actionsAutoCollapse,
  onToggleActionsAutoCollapse,
  className = '',
}: SettingsMenuProps): ReactElement {
  const [isOpen, setIsOpen] = useState(false);
  const [showReorderModal, setShowReorderModal] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  // Close menu when clicking outside
  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    }

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isOpen]);

  return (
    <div ref={menuRef} className={`relative ${className}`}>
      {/* Hamburger button */}
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="p-2 rounded-lg bg-gray-800/80 hover:bg-gray-700 transition-colors"
        title="Settings"
      >
        {isOpen ? <X size={20} /> : <Menu size={20} />}
      </button>

      {/* Dropdown menu */}
      {isOpen && (
        <div data-testid="settings-dropdown" className="absolute top-full mt-2 left-0 w-56 bg-gray-800 rounded-lg shadow-xl border border-gray-700 py-2 z-50">
          <div className="px-3 py-1.5 text-xs text-gray-400 uppercase tracking-wide">
            Global
          </div>

          {/* Tab Bar toggle */}
          <button
            onClick={() => {
              onToggleTabBar();
            }}
            className="w-full px-3 py-2 flex items-center justify-between hover:bg-gray-700/50 transition-colors"
          >
            <span className="text-sm">Tab Bar</span>
            <span className={`flex items-center gap-1.5 text-xs ${showTabBar ? 'text-green-400' : 'text-gray-500'}`}>
              {showTabBar ? <Eye size={14} /> : <EyeOff size={14} />}
              {showTabBar ? 'Visible' : 'Hidden'}
            </span>
          </button>

          {/* Persistent Transport toggle */}
          <button
            onClick={() => {
              onTogglePersistentTransport();
            }}
            className="w-full px-3 py-2 flex items-center justify-between hover:bg-gray-700/50 transition-colors"
          >
            <span className="text-sm">Transport Bar</span>
            <span className={`flex items-center gap-1.5 text-xs ${showPersistentTransport ? 'text-green-400' : 'text-gray-500'}`}>
              {showPersistentTransport ? <Eye size={14} /> : <EyeOff size={14} />}
              {showPersistentTransport ? 'Visible' : 'Hidden'}
            </span>
          </button>

          {/* Transport Position toggle */}
          <button
            onClick={() => {
              onToggleTransportPosition();
            }}
            className="w-full px-3 py-2 flex items-center justify-between hover:bg-gray-700/50 transition-colors"
          >
            <span className="text-sm">Transport Position</span>
            <span className="flex items-center gap-1.5 text-xs text-blue-400">
              <ArrowLeftRight size={14} />
              {transportPosition === 'left' ? 'Left' : 'Right'}
            </span>
          </button>

          {/* Studio section - only shown in Studio view */}
          {currentView === 'studio' && (
            <>
              <div className="my-2 border-t border-gray-700" />

              <div className="px-3 py-1.5 text-xs text-gray-400 uppercase tracking-wide">
                Studio
              </div>

              {/* Reorder Sections button */}
              <button
                onClick={() => {
                  setShowReorderModal(true);
                  setIsOpen(false);
                }}
                className="w-full px-3 py-2 flex items-center justify-between hover:bg-gray-700/50 transition-colors"
              >
                <span className="text-sm">Reorder Sections</span>
                <span className="flex items-center gap-1.5 text-xs text-blue-400">
                  <ArrowLeftRight size={14} />
                </span>
              </button>

              {/* Recording Actions toggle */}
              <button
                onClick={() => {
                  onToggleRecordingActions();
                }}
                className="w-full px-3 py-2 flex items-center justify-between hover:bg-gray-700/50 transition-colors"
              >
                <span className="text-sm">Rec Quick Actions</span>
                <span className={`flex items-center gap-1.5 text-xs ${showRecordingActions ? 'text-green-400' : 'text-gray-500'}`}>
                  {showRecordingActions ? <Eye size={14} /> : <EyeOff size={14} />}
                  {showRecordingActions ? 'Visible' : 'Hidden'}
                </span>
              </button>
            </>
          )}

          {/* Actions section - only shown in Actions view */}
          {currentView === 'actions' && (
            <>
              <div className="my-2 border-t border-gray-700" />

              <div className="px-3 py-1.5 text-xs text-gray-400 uppercase tracking-wide">
                Actions
              </div>

              {/* Auto-collapse toggle */}
              <button
                onClick={() => {
                  onToggleActionsAutoCollapse();
                }}
                className="w-full px-3 py-2 flex items-center justify-between hover:bg-gray-700/50 transition-colors"
              >
                <span className="text-sm">Auto-Collapse Others</span>
                <span className={`flex items-center gap-1.5 text-xs ${actionsAutoCollapse ? 'text-green-400' : 'text-gray-500'}`}>
                  {actionsAutoCollapse ? <Eye size={14} /> : <EyeOff size={14} />}
                  {actionsAutoCollapse ? 'On' : 'Off'}
                </span>
              </button>
            </>
          )}
        </div>
      )}

      {/* Reorder Sections Modal */}
      <ReorderSectionsModal
        isOpen={showReorderModal}
        onClose={() => setShowReorderModal(false)}
      />
    </div>
  );
}
