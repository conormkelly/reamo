/**
 * TrackInfoBar Component
 * Shows track info in the mixer when a track is selected.
 * 2-line layout matching MarkerInfoBar style:
 * - Line 1: Track # | Name (editable)
 * - Line 2: Color (display only) | FX toggle | Routing button | Duplicate | Delete
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { Copy, Trash2, Folder } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { track as trackCmd } from '../../core/WebSocketCommands';
import { reaperColorToHex, hexToReaperColor, formatInputLabel } from '../../utils';
import { DEFAULT_TRACK_COLOR } from '../../constants/colors';
import { isRecordArmed } from '../../core/types';
import { FxModal } from './FxModal';
import { FxBrowserModal } from './FxBrowserModal';
import { FxParamModal } from './FxParamModal';
import { ColorPickerInput } from '../Toolbar/ColorPickerInput';

export interface TrackInfoBarProps {
  /** Currently selected track index (null if no selection) */
  selectedTrackIdx: number | null;
  /** Callback when routing button is clicked */
  onShowRouting?: (trackIdx: number) => void;
  /** Callback when folder badge is clicked (navigates into folder) */
  onFolderClick?: (folderGuid: string) => void;
  className?: string;
}

/** Routing indicator colors from REAPER's native routing UI */
const ROUTING_COLORS = {
  masterSend: 'var(--color-routing-master)', // Aqua - master send enabled
  sends: 'var(--color-routing-sends)', // Yellow - has sends/hw out
  receives: 'var(--color-routing-receives)', // Blue - has receives
  disabled: 'var(--color-routing-disabled)', // Gray - disabled
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
  onFolderClick,
  className = '',
}: TrackInfoBarProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const trackData = useTrack(selectedTrackIdx ?? -1);

  // Get folder info from skeleton (fd === 1 means folder parent)
  // Use separate selectors to avoid object creation on every render
  const isFolder = useReaperStore((state) => {
    if (selectedTrackIdx === null) return false;
    return state.trackSkeleton[selectedTrackIdx]?.fd === 1;
  });

  const childCount = useReaperStore((state) => {
    if (selectedTrackIdx === null) return 0;
    const skeleton = state.trackSkeleton;
    const track = skeleton[selectedTrackIdx];
    if (!track || track.fd !== 1) return 0;

    // Count children by walking forward until folder closes
    let depth = 1;
    let count = 0;
    for (let i = selectedTrackIdx + 1; i < skeleton.length && depth > 0; i++) {
      const fd = skeleton[i].fd;
      if (fd > 0) depth += fd; // Nested folder opens
      else if (fd < 0) depth += fd; // Folder closes (fd is negative)
      count++;
    }
    return count;
  });

  // State for name editing
  const [isEditingName, setIsEditingName] = useState(false);
  const [nameValue, setNameValue] = useState('');
  const nameInputRef = useRef<HTMLInputElement>(null);

  // State for delete confirmation
  const [confirmDelete, setConfirmDelete] = useState(false);
  const deleteTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // State for FX modal (long-press to open)
  const [isFxModalOpen, setIsFxModalOpen] = useState(false);
  const fxPressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const fxLongPressTriggeredRef = useRef(false);

  // State for FX browser modal (opened from FxModal)
  const [isFxBrowserOpen, setIsFxBrowserOpen] = useState(false);

  // State for FX param modal (opened by tapping FX row in FxModal)
  const [selectedFx, setSelectedFx] = useState<{ fxGuid: string; fxName: string } | null>(null);

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
    setIsFxModalOpen(false);
    setIsFxBrowserOpen(false);
    setSelectedFx(null);

    // Cleanup timeouts
    if (deleteTimeoutRef.current) {
      clearTimeout(deleteTimeoutRef.current);
      deleteTimeoutRef.current = null;
    }
    if (fxPressTimerRef.current) {
      clearTimeout(fxPressTimerRef.current);
      fxPressTimerRef.current = null;
    }
  }, [selectedTrackIdx]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (deleteTimeoutRef.current) {
        clearTimeout(deleteTimeoutRef.current);
      }
      if (fxPressTimerRef.current) {
        clearTimeout(fxPressTimerRef.current);
      }
    };
  }, []);

  // Get track color
  const track = trackData.track;
  const isDefaultColor = !track?.color || track.color === 0;
  const currentColor = isDefaultColor
    ? DEFAULT_TRACK_COLOR
    : reaperColorToHex(track.color) ?? DEFAULT_TRACK_COLOR;

  // Color change handler (receives hex string from ColorPickerInput)
  const handleColorChange = useCallback(
    (hex: string) => {
      if (selectedTrackIdx === null) return;
      // If reset to default, send 0; otherwise convert hex to REAPER color
      const reaperColor = hex === DEFAULT_TRACK_COLOR ? 0 : hexToReaperColor(hex);
      sendCommand(trackCmd.setColor(selectedTrackIdx, reaperColor, trackData.guid));
    },
    [selectedTrackIdx, trackData.guid, sendCommand]
  );

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

  // FX button handlers - tap to toggle (if has FX), long-press to open modal (always)
  const handleFxPointerDown = useCallback(() => {
    if (selectedTrackIdx === null || !trackData.exists) return;

    fxLongPressTriggeredRef.current = false;
    fxPressTimerRef.current = setTimeout(() => {
      fxLongPressTriggeredRef.current = true;
      setIsFxModalOpen(true);
      fxPressTimerRef.current = null;
    }, 500);
  }, [selectedTrackIdx, trackData.exists]);

  const handleFxPointerUp = useCallback(() => {
    // Cancel long-press timer if still pending
    if (fxPressTimerRef.current) {
      clearTimeout(fxPressTimerRef.current);
      fxPressTimerRef.current = null;
    }
  }, []);

  const handleFxClick = useCallback(() => {
    if (selectedTrackIdx === null || !trackData.exists) return;

    // If long-press triggered, don't toggle (modal is already open)
    if (fxLongPressTriggeredRef.current) {
      fxLongPressTriggeredRef.current = false;
      return;
    }

    // Only toggle if track has FX - otherwise tap does nothing (hold to add FX)
    if (trackData.fxCount === 0) return;

    // Toggle FX enabled state (undefined = toggle)
    sendCommand(trackCmd.setFxEnabled(selectedTrackIdx, undefined, trackData.guid));
  }, [selectedTrackIdx, trackData.exists, trackData.fxCount, trackData.guid, sendCommand]);

  const handleFxModalClose = useCallback(() => {
    setIsFxModalOpen(false);
  }, []);

  const handleAddFx = useCallback(() => {
    setIsFxBrowserOpen(true);
  }, []);

  const handleFxBrowserClose = useCallback(() => {
    setIsFxBrowserOpen(false);
  }, []);

  const handleOpenFxParams = useCallback((fxGuid: string, fxName: string) => {
    setSelectedFx({ fxGuid, fxName });
  }, []);

  const handleFxParamClose = useCallback(() => {
    setSelectedFx(null);
  }, []);

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

          {/* Input indicator for armed tracks */}
          {track && isRecordArmed(track) && track.recInput !== undefined && (
            <>
              <div className="w-px h-4 bg-border-default flex-shrink-0" />
              <span className="text-xs text-text-muted truncate flex-shrink-0">
                {formatInputLabel(track.recInput)}
              </span>
            </>
          )}

          {/* Folder indicator with child count (top right) - clickable to navigate */}
          {isFolder && trackData.guid && (
            <button
              onClick={() => onFolderClick?.(trackData.guid!)}
              className="flex items-center gap-1 text-text-muted/50 hover:text-text-muted flex-shrink-0 ml-auto transition-colors"
              title="View folder contents"
            >
              <Folder size={16} />
              <span className="text-xs">({childCount})</span>
            </button>
          )}
        </div>

        {/* Line 2: Color, Routing, Duplicate, Delete */}
        <div className="flex items-center gap-3">
          {/* Color picker with hold-to-reset (not for master track) */}
          {!isMaster && (
            <>
              <ColorPickerInput
                label="Color"
                value={currentColor}
                onChange={handleColorChange}
                defaultValue={DEFAULT_TRACK_COLOR}
                compact
              />

              <div className="w-px h-6 bg-border-default flex-shrink-0" />
            </>
          )}

          {/* FX indicator/toggle - tap to toggle, long-press for modal */}
          <button
            onClick={handleFxClick}
            onPointerDown={handleFxPointerDown}
            onPointerUp={handleFxPointerUp}
            onPointerCancel={handleFxPointerUp}
            onPointerLeave={handleFxPointerUp}
            className={`w-8 h-8 flex items-center justify-center rounded-lg border-2 transition-colors ${
              trackData.fxCount === 0
                ? 'text-text-muted border-border-default hover:bg-bg-elevated hover:text-text-secondary'
                : trackData.isFxDisabled
                  ? 'text-error-text border-error-text hover:bg-bg-elevated'
                  : 'text-success border-success hover:bg-bg-elevated'
            }`}
            title={
              trackData.fxCount === 0
                ? 'No FX - hold to add'
                : trackData.isFxDisabled
                  ? `FX bypassed (${trackData.fxCount} FX) - tap to toggle, hold for details`
                  : `FX enabled (${trackData.fxCount} FX) - tap to toggle, hold for details`
            }
          >
            <span className="text-xs font-bold">FX</span>
          </button>

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

      {/* FX Modal */}
      {selectedTrackIdx !== null && (
        <FxModal
          isOpen={isFxModalOpen}
          onClose={handleFxModalClose}
          trackIndex={selectedTrackIdx}
          onAddFx={handleAddFx}
          onOpenFxParams={handleOpenFxParams}
        />
      )}

      {/* FX Browser Modal */}
      {selectedTrackIdx !== null && trackData.guid && (
        <FxBrowserModal
          isOpen={isFxBrowserOpen}
          onClose={handleFxBrowserClose}
          trackGuid={trackData.guid}
          trackName={trackData.name || `Track ${selectedTrackIdx + 1}`}
        />
      )}

      {/* FX Param Modal */}
      {selectedTrackIdx !== null && trackData.guid && selectedFx && (
        <FxParamModal
          isOpen={!!selectedFx}
          onClose={handleFxParamClose}
          trackGuid={trackData.guid}
          fxGuid={selectedFx.fxGuid}
          fxName={selectedFx.fxName}
        />
      )}
    </div>
  );
}
