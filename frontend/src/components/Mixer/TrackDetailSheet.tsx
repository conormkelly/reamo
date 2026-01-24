/**
 * TrackDetailSheet - BottomSheet for track controls in landscape mode
 *
 * Shows the controls that are hidden in MixerStripCompact:
 * - Pan control
 * - Mute/Solo buttons
 * - RecordArm/Monitor buttons (or Mono for master)
 *
 * The sheet stays open and switches context when tapping different tracks.
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { useReaper } from '../ReaperProvider';
import { track as trackCmd } from '../../core/WebSocketCommands';
import { BottomSheet } from '../Modal/BottomSheet';
import {
  MuteButton,
  SoloButton,
  RecordArmButton,
  MonitorButton,
  MasterMonoButton,
  PanKnob,
} from '../Track';

export interface TrackDetailSheetProps {
  /** Track index to display (-1 or undefined = closed) */
  trackIndex: number | undefined;
  /** Whether the sheet is open */
  isOpen: boolean;
  /** Callback to close the sheet */
  onClose: () => void;
}

/**
 * Bottom sheet showing track controls for landscape mode.
 *
 * Displays pan, M/S, and arm/monitor controls that aren't visible
 * on MixerStripCompact. Stays open when switching between tracks.
 */
export function TrackDetailSheet({
  trackIndex,
  isOpen,
  onClose,
}: TrackDetailSheetProps): ReactElement {
  // Always call hooks, use trackIndex 0 as fallback when undefined
  const safeTrackIndex = trackIndex ?? 0;
  const { exists, name, isSelected, color, guid } = useTrack(safeTrackIndex);
  const { sendCommand } = useReaper();

  const isMaster = safeTrackIndex === 0;
  const displayName = isMaster ? 'MASTER' : name || `Track ${safeTrackIndex}`;
  const topBarColor = color || 'var(--color-text-muted)';

  // Toggle track selection in REAPER when tapping name
  const handleToggleSelectInReaper = () => {
    sendCommand(trackCmd.setSelected(safeTrackIndex, isSelected ? 0 : 1, guid));
  };

  // Don't show anything if track doesn't exist
  if (!exists && trackIndex !== undefined) {
    return (
      <BottomSheet isOpen={isOpen} onClose={onClose} ariaLabel="Track details">
        <div className="p-4 text-center text-text-muted">
          Track not found
        </div>
      </BottomSheet>
    );
  }

  return (
    <BottomSheet isOpen={isOpen} onClose={onClose} ariaLabel={`${displayName} controls`}>
      {/* Color bar + track name header */}
      <div className="px-4 pb-3">
        <div
          className="h-1 rounded-full mb-3"
          style={{ backgroundColor: topBarColor }}
        />
        <button
          onClick={handleToggleSelectInReaper}
          className={`w-full text-left text-lg font-semibold px-2 py-1 rounded transition-colors ${
            isSelected ? 'bg-bg-elevated text-text-primary' : 'text-text-primary hover:bg-bg-hover'
          }`}
          style={color ? { color } : undefined}
          title={`${displayName} - tap to ${isSelected ? 'deselect' : 'select'}`}
        >
          {displayName}
          {!isMaster && (
            <span className="ml-2 text-sm text-text-muted font-normal">
              #{safeTrackIndex}
            </span>
          )}
        </button>
      </div>

      {/* Controls grid */}
      <div className="px-4 pb-6 space-y-4">
        {/* Pan control - wider for better touch target */}
        <div className="flex justify-center">
          <PanKnob
            trackIndex={safeTrackIndex}
            width={200}
            isSelected={isSelected}
          />
        </div>

        {/* M/S buttons */}
        <div className="flex justify-center gap-3">
          <MuteButton trackIndex={safeTrackIndex} isSelected={isSelected} />
          <SoloButton trackIndex={safeTrackIndex} isSelected={isSelected} />
        </div>

        {/* Arm/Monitor or Mono button */}
        <div className="flex justify-center gap-3">
          {isMaster ? (
            <MasterMonoButton isSelected={isSelected} />
          ) : (
            <>
              <RecordArmButton trackIndex={safeTrackIndex} isSelected={isSelected} />
              <MonitorButton trackIndex={safeTrackIndex} isSelected={isSelected} />
            </>
          )}
        </div>
      </div>
    </BottomSheet>
  );
}
