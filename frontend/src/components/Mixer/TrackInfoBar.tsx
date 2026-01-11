/**
 * TrackInfoBar Component
 * Shows track info in the mixer when a track is selected.
 * 2-line layout matching MarkerInfoBar style:
 * - Line 1: Track # | Name (editable)
 * - Line 2: Color (display only) | Routing button | Duplicate | Delete
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { Copy, Trash2 } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { track as trackCmd } from '../../core/WebSocketCommands';
import { reaperColorToHex } from '../../utils';
import { DEFAULT_TRACK_COLOR } from '../../constants/colors';

export interface TrackInfoBarProps {
  /** Currently selected track index (null if no selection) */
  selectedTrackIdx: number | null;
  /** Callback when routing button is clicked */
  onShowRouting?: (trackIdx: number) => void;
  className?: string;
}

/** Routing indicator colors from REAPER's native routing UI */
const ROUTING_COLORS = {
  masterSend: '#00B4C5', // Aqua - master send enabled
  sends: '#C5A000', // Yellow - has sends/hw out
  receives: '#0077C5', // Blue - has receives
  disabled: '#4A4A4A', // Gray - disabled
} as const;

/**
 * RoutingIndicator - Three forward slashes showing routing status
 * - Slash 1: Master send (aqua)
 * - Slash 2: Sends/HW out (yellow)
 * - Slash 3: Receives (blue)
 */
function RoutingIndicator({
  hasMasterSend,
  hasSends,
  hasReceives,
  onClick,
}: {
  hasMasterSend: boolean;
  hasSends: boolean;
  hasReceives: boolean;
  onClick?: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex items-center justify-center w-11 h-11 rounded-lg hover:bg-bg-elevated transition-colors"
      title="View routing"
    >
      {/* Three thick forward slashes */}
      <svg width="32" height="22" viewBox="0 0 32 22" className="flex-shrink-0">
        {/* Master send slash */}
        <line
          x1="4"
          y1="19"
          x2="9"
          y2="3"
          stroke={hasMasterSend ? ROUTING_COLORS.masterSend : ROUTING_COLORS.disabled}
          strokeWidth="4"
          strokeLinecap="round"
        />
        {/* Sends slash */}
        <line
          x1="13"
          y1="19"
          x2="18"
          y2="3"
          stroke={hasSends ? ROUTING_COLORS.sends : ROUTING_COLORS.disabled}
          strokeWidth="4"
          strokeLinecap="round"
        />
        {/* Receives slash */}
        <line
          x1="22"
          y1="19"
          x2="27"
          y2="3"
          stroke={hasReceives ? ROUTING_COLORS.receives : ROUTING_COLORS.disabled}
          strokeWidth="4"
          strokeLinecap="round"
        />
      </svg>
    </button>
  );
}

export function TrackInfoBar({
  selectedTrackIdx,
  onShowRouting,
  className = '',
}: TrackInfoBarProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const trackData = useTrack(selectedTrackIdx ?? -1);

  // State for name editing
  const [isEditingName, setIsEditingName] = useState(false);
  const [nameValue, setNameValue] = useState('');
  const nameInputRef = useRef<HTMLInputElement>(null);

  // State for delete confirmation
  const [confirmDelete, setConfirmDelete] = useState(false);
  const deleteTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Focus name input when editing starts
  useEffect(() => {
    if (isEditingName && nameInputRef.current) {
      nameInputRef.current.focus();
      nameInputRef.current.select();
    }
  }, [isEditingName]);

  // Reset state when track changes
  useEffect(() => {
    setIsEditingName(false);
    setConfirmDelete(false);

    // Cleanup delete timeout
    if (deleteTimeoutRef.current) {
      clearTimeout(deleteTimeoutRef.current);
      deleteTimeoutRef.current = null;
    }
  }, [selectedTrackIdx]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (deleteTimeoutRef.current) {
        clearTimeout(deleteTimeoutRef.current);
      }
    };
  }, []);

  // Get track color (display only - backend doesn't support track/setColor yet)
  const track = trackData.track;
  const isDefaultColor = !track?.color || track.color === 0;
  const currentColor = isDefaultColor
    ? DEFAULT_TRACK_COLOR
    : reaperColorToHex(track.color) ?? DEFAULT_TRACK_COLOR;

  // Routing status - master send is typically enabled by default
  // TODO: Add actual master send state when backend supports it
  const hasMasterSend = true; // Default assumption
  const hasSends = (track?.sendCount ?? 0) > 0 || (track?.hwOutCount ?? 0) > 0;
  const hasReceives = (track?.receiveCount ?? 0) > 0;

  // Name editing handlers
  const handleNameClick = useCallback(() => {
    if (!trackData.exists) return;
    setNameValue(trackData.name);
    setIsEditingName(true);
  }, [trackData.exists, trackData.name]);

  const handleNameConfirm = useCallback(() => {
    if (selectedTrackIdx === null || !trackData.exists) {
      setIsEditingName(false);
      return;
    }

    const trimmedName = nameValue.trim();
    if (trimmedName && trimmedName !== trackData.name) {
      sendCommand(trackCmd.rename(selectedTrackIdx, trimmedName));
    }

    setIsEditingName(false);
  }, [selectedTrackIdx, trackData.exists, trackData.name, nameValue, sendCommand]);

  const handleNameCancel = useCallback(() => {
    setIsEditingName(false);
  }, []);

  const handleNameKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        handleNameConfirm();
      } else if (e.key === 'Escape') {
        e.preventDefault();
        handleNameCancel();
      }
    },
    [handleNameConfirm, handleNameCancel]
  );

  // Action handlers
  const handleDuplicate = useCallback(() => {
    if (selectedTrackIdx === null || selectedTrackIdx === 0) return; // Can't duplicate master
    sendCommand(trackCmd.duplicate(selectedTrackIdx));
  }, [selectedTrackIdx, sendCommand]);

  const handleDelete = useCallback(() => {
    if (selectedTrackIdx === null || selectedTrackIdx === 0) return; // Can't delete master

    if (!confirmDelete) {
      // First click - show confirmation
      setConfirmDelete(true);
      // Auto-reset after 3 seconds
      deleteTimeoutRef.current = setTimeout(() => {
        setConfirmDelete(false);
      }, 3000);
    } else {
      // Second click - actually delete
      sendCommand(trackCmd.delete(selectedTrackIdx));
      setConfirmDelete(false);
      if (deleteTimeoutRef.current) {
        clearTimeout(deleteTimeoutRef.current);
        deleteTimeoutRef.current = null;
      }
    }
  }, [selectedTrackIdx, confirmDelete, sendCommand]);

  const handleShowRouting = useCallback(() => {
    if (selectedTrackIdx !== null && onShowRouting) {
      onShowRouting(selectedTrackIdx);
    }
  }, [selectedTrackIdx, onShowRouting]);

  // Don't render if no track selected
  if (selectedTrackIdx === null || !trackData.exists) {
    return (
      <div className={`flex items-center gap-2 min-w-0 ${className}`}>
        <div className="flex flex-col gap-1 px-3 py-1.5 bg-bg-surface/50 rounded-lg text-sm flex-1 min-w-0">
          <span className="text-text-muted text-sm italic">Select a track to view details</span>
        </div>
      </div>
    );
  }

  const isMaster = selectedTrackIdx === 0;

  return (
    <div className={`flex items-center gap-2 min-w-0 ${className}`}>
      <div className="flex flex-col gap-2 px-3 py-2 bg-bg-surface/50 rounded-lg text-sm flex-1 min-w-0">
        {/* Line 1: Track # and Name */}
        <div className="flex items-center gap-3 min-w-0">
          {/* Track number */}
          <div className="flex items-center gap-1.5">
            <span className="text-text-secondary text-xs">Track:</span>
            <span className="text-text-primary font-mono text-xs font-bold">
              {isMaster ? 'M' : selectedTrackIdx}
            </span>
          </div>

          <div className="w-px h-4 bg-border-default flex-shrink-0" />

          {/* Name (editable for non-master) */}
          <div className="flex items-center gap-1.5 flex-1 min-w-0">
            <span className="text-text-secondary text-xs flex-shrink-0">Name:</span>
            {isEditingName && !isMaster ? (
              <input
                ref={nameInputRef}
                type="text"
                value={nameValue}
                onChange={(e) => setNameValue(e.target.value)}
                onKeyDown={handleNameKeyDown}
                onBlur={handleNameConfirm}
                className="flex-1 min-w-0 px-1.5 py-0.5 bg-bg-elevated border border-focus-border rounded text-text-primary font-mono text-base focus:outline-none focus:ring-1 focus:ring-focus-ring"
              />
            ) : (
              <button
                onClick={handleNameClick}
                disabled={isMaster}
                className={`text-text-primary font-mono text-sm px-1.5 py-0.5 rounded transition-colors truncate min-w-0 ${
                  isMaster ? 'cursor-default' : 'hover:bg-bg-elevated cursor-pointer'
                }`}
                title={isMaster ? 'Master track' : 'Click to edit name'}
              >
                {trackData.name || (isMaster ? 'MASTER' : `Track ${selectedTrackIdx}`)}
              </button>
            )}
          </div>
        </div>

        {/* Line 2: Color, Routing, Duplicate, Delete */}
        <div className="flex items-center gap-3">
          {/* Color indicator (display only - TODO: enable editing when backend supports track/setColor) */}
          <div className="flex items-center gap-2">
            <span className="text-text-secondary text-sm">Color:</span>
            <div
              className="w-8 h-8 rounded-lg border-2 border-border-default"
              style={{ backgroundColor: currentColor }}
              title="Track color (read-only)"
            />
          </div>

          <div className="w-px h-6 bg-border-default flex-shrink-0" />

          {/* Routing indicator */}
          <RoutingIndicator
            hasMasterSend={hasMasterSend}
            hasSends={hasSends}
            hasReceives={hasReceives}
            onClick={handleShowRouting}
          />

          {/* Spacer */}
          <div className="flex-1" />

          {/* Actions (not for master track) */}
          {!isMaster && (
            <div className="flex items-center gap-2">
              {/* Duplicate */}
              <button
                onClick={handleDuplicate}
                className="w-11 h-11 flex items-center justify-center rounded-lg hover:bg-bg-elevated transition-colors"
                title="Duplicate track"
              >
                <Copy size={20} className="text-text-secondary" />
              </button>

              {/* Delete (with confirmation) */}
              <button
                onClick={handleDelete}
                className={`w-11 h-11 flex items-center justify-center rounded-lg transition-colors ${
                  confirmDelete
                    ? 'bg-error-bg text-error-text'
                    : 'hover:bg-bg-elevated text-text-secondary hover:text-error-text'
                }`}
                title={confirmDelete ? 'Click again to confirm delete' : 'Delete track'}
              >
                <Trash2 size={20} />
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
