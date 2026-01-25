/**
 * FxModal - View and control track FX chain
 * Shows FX list with preset navigation and bypass controls.
 * Uses real-time subscription for instant updates when FX changes.
 * Uses BottomSheet for slide-up panel UX.
 */

import { useEffect, useCallback, type ReactElement } from 'react';
import { ChevronLeft, ChevronRight, CircleDot, Plus } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useTrack } from '../../hooks/useTrack';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { fx as fxCmd, track as trackCmd, trackFx } from '../../core/WebSocketCommands';
import type { WSFxChainSlot } from '../../core/WebSocketTypes';

export interface FxModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Track index to show FX for */
  trackIndex: number;
  /** Called when user wants to add FX */
  onAddFx?: () => void;
  /** Called when user taps an FX row to edit params */
  onOpenFxParams?: (fxGuid: string, fxName: string) => void;
}

/**
 * Single FX row with preset navigation
 * Now tappable to open FX param editor
 */
function FxRow({
  trackIdx,
  trackGuid,
  fxIndex,
  name,
  presetName,
  presetIndex,
  presetCount,
  modified,
  enabled,
  onTap,
}: {
  trackIdx: number;
  trackGuid?: string;
  fxIndex: number;
  name: string;
  presetName: string;
  presetIndex: number;
  presetCount: number;
  modified: boolean;
  enabled: boolean;
  onTap?: () => void;
}): ReactElement {
  const { sendCommand } = useReaper();

  const handlePrevPreset = useCallback((e: React.MouseEvent) => {
    e.stopPropagation(); // Don't trigger row tap
    sendCommand(fxCmd.presetPrev(trackIdx, fxIndex));
    // No need to refetch - subscription updates automatically
  }, [sendCommand, trackIdx, fxIndex]);

  const handleNextPreset = useCallback((e: React.MouseEvent) => {
    e.stopPropagation(); // Don't trigger row tap
    sendCommand(fxCmd.presetNext(trackIdx, fxIndex));
    // No need to refetch - subscription updates automatically
  }, [sendCommand, trackIdx, fxIndex]);

  const handleToggleBypass = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    e.stopPropagation(); // Don't trigger row tap
    // Toggle FX enabled state (undefined = toggle)
    sendCommand(trackFx.setEnabled(trackIdx, fxIndex, undefined, trackGuid));
    // No need to refetch - subscription updates automatically
  }, [sendCommand, trackIdx, fxIndex, trackGuid]);

  // Display preset info
  const presetDisplay = presetName || '(no preset)';
  const presetCounter =
    presetCount > 0 ? `${presetIndex + 1}/${presetCount}` : '';

  return (
    <div
      onClick={onTap}
      className={`flex items-center gap-3 py-3 px-3 rounded-lg cursor-pointer transition-colors ${
        enabled
          ? 'bg-bg-surface hover:bg-bg-elevated'
          : 'bg-bg-surface/50 opacity-60 hover:bg-bg-surface/70'
      }`}
    >
      {/* FX number badge */}
      <div className="w-7 h-7 flex items-center justify-center rounded bg-bg-elevated text-text-secondary text-xs font-bold">
        {fxIndex + 1}
      </div>

      {/* FX name and preset */}
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium text-text-primary truncate">
            {name}
          </span>
          {modified && (
            <span title="Preset modified">
              <CircleDot size={12} className="text-warning flex-shrink-0" />
            </span>
          )}
          {!enabled && (
            <span className="text-xs text-error-text">(bypassed)</span>
          )}
        </div>
        <div className="text-xs text-text-secondary truncate" title={presetDisplay}>
          {presetDisplay}
          {presetCounter && (
            <span className="text-text-tertiary ml-1">({presetCounter})</span>
          )}
        </div>
      </div>

      {/* FX bypass toggle */}
      <input
        type="checkbox"
        checked={enabled}
        onChange={handleToggleBypass}
        onClick={(e) => e.stopPropagation()}
        className="w-5 h-5 accent-success cursor-pointer"
        title={enabled ? 'Bypass FX' : 'Enable FX'}
      />

      {/* Preset navigation */}
      {presetCount > 0 && (
        <div className="flex items-center gap-1">
          <button
            onClick={handlePrevPreset}
            disabled={presetIndex <= 0}
            className="w-9 h-9 flex items-center justify-center rounded-lg hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-default transition-colors"
            title="Previous preset"
          >
            <ChevronLeft size={20} className="text-text-secondary" />
          </button>
          <button
            onClick={handleNextPreset}
            disabled={presetIndex >= presetCount - 1}
            className="w-9 h-9 flex items-center justify-center rounded-lg hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-default transition-colors"
            title="Next preset"
          >
            <ChevronRight size={20} className="text-text-secondary" />
          </button>
        </div>
      )}
    </div>
  );
}

export function FxModal({
  isOpen,
  onClose,
  trackIndex,
  onAddFx,
  onOpenFxParams,
}: FxModalProps): ReactElement {
  const { sendCommand } = useReaper();
  const { name: trackName, isFxDisabled, guid } = useTrack(trackIndex);

  // Use subscription-based FX chain data from store
  const fxChainList = useReaperStore((s) => s.fxChainList);
  const setFxChainSubscription = useReaperStore((s) => s.setFxChainSubscription);
  const clearFxChainSubscription = useReaperStore((s) => s.clearFxChainSubscription);

  // Subscribe on open, unsubscribe on close (like RoutingModal pattern)
  useEffect(() => {
    if (isOpen && guid) {
      setFxChainSubscription(guid);
      sendCommand(trackFx.subscribe(guid));
      return () => {
        sendCommand(trackFx.unsubscribe());
        clearFxChainSubscription();
      };
    }
  }, [isOpen, guid, sendCommand, setFxChainSubscription, clearFxChainSubscription]);

  // Toggle track-level FX bypass
  const handleToggleBypass = useCallback(() => {
    sendCommand(trackCmd.setFxEnabled(trackIndex, undefined, guid));
  }, [sendCommand, trackIndex, guid]);

  // Handle FX row tap to open params
  const handleFxRowTap = useCallback((fx: WSFxChainSlot) => {
    onOpenFxParams?.(fx.fxGuid, fx.name);
  }, [onOpenFxParams]);

  return (
    <BottomSheet
      isOpen={isOpen}
      onClose={onClose}
      ariaLabel={`FX chain for ${trackName || `Track ${trackIndex}`}`}
    >
      <div className="px-sheet-x pb-sheet-bottom">
        {/* Header */}
        <div className="text-center mb-3 pt-1">
          <h2 className="text-lg font-semibold text-text-primary truncate">
            FX: {trackName || `Track ${trackIndex}`}
          </h2>
        </div>

        {/* Track-level bypass toggle */}
        <div className="flex items-center justify-between py-2 px-1 mb-3 border-b border-border-subtle">
          <span className="text-sm text-text-secondary">Track FX Chain</span>
          <button
            onClick={handleToggleBypass}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-colors ${
              isFxDisabled
                ? 'bg-error-bg text-error-text'
                : 'bg-success/20 text-success'
            }`}
          >
            {isFxDisabled ? 'Bypassed' : 'Enabled'}
          </button>
        </div>

        {/* Scrollable content area */}
        <div className="max-h-80 overflow-y-auto -mx-4 px-4">
          {/* FX list */}
          {fxChainList.length === 0 && (
            <div className="py-8 text-center text-text-muted text-sm">
              No FX on this track
            </div>
          )}

          {fxChainList.length > 0 && (
            <div className="space-y-2">
              {fxChainList.map((fx) => (
                <FxRow
                  key={fx.fxGuid}
                  trackIdx={trackIndex}
                  trackGuid={guid}
                  fxIndex={fx.fxIndex}
                  name={fx.name}
                  presetName={fx.presetName}
                  presetIndex={fx.presetIndex}
                  presetCount={fx.presetCount}
                  modified={fx.modified}
                  enabled={fx.enabled}
                  onTap={() => handleFxRowTap(fx)}
                />
              ))}
            </div>
          )}
        </div>

        {/* Footer with Add FX button */}
        <div className="mt-3 pt-3 border-t border-border-subtle">
          {fxChainList.length > 0 && (
            <div className="text-xs text-text-muted text-center mb-3">
              {fxChainList.length} FX plugin{fxChainList.length !== 1 ? 's' : ''}
              <span className="text-text-tertiary ml-2">• Tap to edit params</span>
            </div>
          )}
          {onAddFx && (
            <button
              onClick={onAddFx}
              className="w-full py-3 flex items-center justify-center gap-2 rounded-lg bg-bg-surface hover:bg-bg-elevated text-text-secondary hover:text-text-primary transition-colors"
            >
              <Plus size={18} />
              <span className="text-sm font-medium">Add FX</span>
            </button>
          )}
        </div>
      </div>
    </BottomSheet>
  );
}
