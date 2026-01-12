/**
 * FxModal - View and control track FX chain
 * Shows FX list with preset navigation and bypass controls.
 * Fetches FX data on-demand via track/getFx command.
 * Uses BottomSheet for slide-up panel UX.
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { ChevronLeft, ChevronRight, CircleDot, Loader2 } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useTrack } from '../../hooks/useTrack';
import { useReaper } from '../ReaperProvider';
import { fx as fxCmd, track as trackCmd, trackFx } from '../../core/WebSocketCommands';

export interface FxModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Track index to show FX for */
  trackIndex: number;
}

/** FX slot data from track/getFx response */
interface FxSlot {
  fxIndex: number;
  name: string;
  presetName: string;
  presetIndex: number;
  presetCount: number;
  modified: boolean;
  enabled: boolean;
}

/** Response type for track/getFx command */
interface GetFxResponse {
  success?: boolean;
  payload?: { fx?: FxSlot[] };
  error?: { message?: string };
}

/**
 * Single FX row with preset navigation
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
  onPresetChange,
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
  onPresetChange: () => void;
}): ReactElement {
  const { sendCommand } = useReaper();

  const handlePrevPreset = useCallback(() => {
    sendCommand(fxCmd.presetPrev(trackIdx, fxIndex));
    // Refetch after a short delay to get updated preset info
    setTimeout(onPresetChange, 100);
  }, [sendCommand, trackIdx, fxIndex, onPresetChange]);

  const handleNextPreset = useCallback(() => {
    sendCommand(fxCmd.presetNext(trackIdx, fxIndex));
    // Refetch after a short delay to get updated preset info
    setTimeout(onPresetChange, 100);
  }, [sendCommand, trackIdx, fxIndex, onPresetChange]);

  const handleToggleBypass = useCallback(() => {
    // Toggle FX enabled state (undefined = toggle)
    sendCommand(trackFx.setEnabled(trackIdx, fxIndex, undefined, trackGuid));
    // Refetch after a short delay to get updated state
    setTimeout(onPresetChange, 100);
  }, [sendCommand, trackIdx, fxIndex, trackGuid, onPresetChange]);

  // Display preset info
  const presetDisplay = presetName || '(no preset)';
  const presetCounter =
    presetCount > 0 ? `${presetIndex + 1}/${presetCount}` : '';

  return (
    <div
      className={`flex items-center gap-3 py-3 px-3 rounded-lg ${
        enabled ? 'bg-bg-surface' : 'bg-bg-surface/50 opacity-60'
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
}: FxModalProps): ReactElement {
  const { sendCommand, sendCommandAsync } = useReaper();
  const { name: trackName, isFxDisabled, guid, fxCount } = useTrack(trackIndex);

  // Local FX data fetched on-demand
  const [fxList, setFxList] = useState<FxSlot[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Fetch FX data when modal opens
  const fetchFxData = useCallback(async () => {
    if (!isOpen || fxCount === 0) {
      setFxList([]);
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const response = (await sendCommandAsync(
        trackCmd.getFx(trackIndex)
      )) as GetFxResponse;
      if (response.success && response.payload?.fx) {
        setFxList(response.payload.fx);
      } else {
        setError(response.error?.message || 'Failed to fetch FX data');
      }
    } catch (err) {
      setError('Failed to fetch FX data');
    } finally {
      setIsLoading(false);
    }
  }, [isOpen, trackIndex, fxCount, sendCommandAsync]);

  // Fetch on open and when track changes
  useEffect(() => {
    if (isOpen) {
      fetchFxData();
    } else {
      // Clear data when modal closes
      setFxList([]);
      setError(null);
    }
  }, [isOpen, trackIndex, fetchFxData]);

  // Toggle track-level FX bypass
  const handleToggleBypass = useCallback(() => {
    sendCommand(trackCmd.setFxEnabled(trackIndex, undefined, guid));
  }, [sendCommand, trackIndex, guid]);

  return (
    <BottomSheet
      isOpen={isOpen}
      onClose={onClose}
      ariaLabel={`FX chain for ${trackName || `Track ${trackIndex}`}`}
    >
      <div className="px-4 pb-6">
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
          {/* Loading state */}
          {isLoading && (
            <div className="py-8 flex justify-center">
              <Loader2 size={24} className="animate-spin text-text-muted" />
            </div>
          )}

          {/* Error state */}
          {error && !isLoading && (
            <div className="py-8 text-center text-error-text text-sm">
              {error}
            </div>
          )}

          {/* FX list */}
          {!isLoading && !error && fxList.length === 0 && (
            <div className="py-8 text-center text-text-muted text-sm">
              No FX on this track
            </div>
          )}

          {!isLoading && !error && fxList.length > 0 && (
            <div className="space-y-2">
              {fxList.map((fx) => (
                <FxRow
                  key={`${trackIndex}-${fx.fxIndex}`}
                  trackIdx={trackIndex}
                  trackGuid={guid}
                  fxIndex={fx.fxIndex}
                  name={fx.name}
                  presetName={fx.presetName}
                  presetIndex={fx.presetIndex}
                  presetCount={fx.presetCount}
                  modified={fx.modified}
                  enabled={fx.enabled}
                  onPresetChange={fetchFxData}
                />
              ))}
            </div>
          )}
        </div>

        {/* Footer summary */}
        {!isLoading && !error && fxList.length > 0 && (
          <div className="text-xs text-text-muted text-center mt-3 pt-3 border-t border-border-subtle">
            {fxList.length} FX plugin{fxList.length !== 1 ? 's' : ''}
          </div>
        )}
      </div>
    </BottomSheet>
  );
}
