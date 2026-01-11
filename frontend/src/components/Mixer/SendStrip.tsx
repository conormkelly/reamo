/**
 * SendStrip Component
 * Channel strip for Sends mode - gold faders controlling send levels.
 * Shows send level to the selected destination for each track.
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { useReaper } from '../ReaperProvider';
import { track as trackCmd } from '../../core/WebSocketCommands';
import { LevelMeter } from '../Track';
import { SendFader } from './SendFader';
import { SendMuteButton } from './SendMuteButton';

export interface SendStripProps {
  /** Source track index */
  trackIndex: number;
  /** Destination track index (the send target) */
  destTrackIdx: number;
  /** Destination track name */
  destName: string;
  /** Fader height in pixels */
  faderHeight?: number;
  /** Whether to show the dB label below the fader */
  showDbLabel?: boolean;
  /** Whether this track is selected for info display (shows in TrackInfoBar) */
  isInfoSelected?: boolean;
  /** Callback when track is selected for info display */
  onSelectForInfo?: (trackIndex: number) => void;
  className?: string;
}

/**
 * Channel strip for Sends mode.
 *
 * Layout:
 * - Color bar with track number
 * - Track name
 * - Meter + Gold Send Fader + dB
 * - Send Mute button
 * - Destination name (→ Bus name)
 */
export function SendStrip({
  trackIndex,
  destTrackIdx,
  destName,
  faderHeight = 180,
  showDbLabel = true,
  isInfoSelected = false,
  onSelectForInfo,
  className = '',
}: SendStripProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const { exists, name, isSelected, color, guid } = useTrack(trackIndex);

  // Toggle track selection in REAPER when tapping name
  const handleToggleSelectInReaper = () => {
    sendCommand(trackCmd.setSelected(trackIndex, isSelected ? 0 : 1, guid));
  };

  if (!exists) {
    return null;
  }

  // Master track (index 0) styling
  const isMaster = trackIndex === 0;

  // Get background color based on selection
  const backgroundColor = isSelected ? 'bg-bg-elevated' : 'bg-bg-surface';

  // Color bar styling
  const topBarColor = color || 'var(--color-text-muted)';

  // Border color based on info selection (send mode has amber tint)
  const borderClass = isInfoSelected
    ? 'border-2 border-accent-region'
    : 'border border-sends-border';

  return (
    <div
      className={`flex flex-col items-center rounded-lg ${borderClass} ${backgroundColor} ${className}`}
      style={{ width: 80 }}
      data-testid="send-strip"
      data-track-index={trackIndex}
    >
      {/* Color bar with track number */}
      <div
        className="w-full h-2 rounded-t-lg flex items-center justify-center"
        style={{ backgroundColor: topBarColor }}
      >
        {!isMaster && (
          <span className="text-[8px] font-medium text-white/80">
            {trackIndex}
          </span>
        )}
      </div>

      {/* Track name - tappable to toggle selection in REAPER */}
      <button
        onClick={handleToggleSelectInReaper}
        className={`w-full text-center text-xs font-medium truncate px-2 py-2 hover:bg-bg-elevated/50 transition-colors rounded-sm ${
          isSelected ? 'bg-bg-elevated/30' : ''
        }`}
        title={`${name || (isMaster ? 'MASTER' : `Trk ${trackIndex}`)} - tap to ${isSelected ? 'deselect' : 'select'}`}
        style={color ? { color } : undefined}
      >
        {isMaster ? 'MASTER' : name || `Trk ${trackIndex}`}
      </button>

      {/* Main content area - meter + send fader */}
      <div className="flex gap-1 px-1 pb-1">
        {/* Level meter (still shows track level for reference) */}
        <LevelMeter
          trackIndex={trackIndex}
          height={faderHeight}
          showPeak={true}
        />

        {/* Send Fader (gold) */}
        <SendFader
          trackIndex={trackIndex}
          destTrackIdx={destTrackIdx}
          height={faderHeight}
          isSelected={isSelected}
          showDbLabel={showDbLabel}
        />
      </div>

      {/* Send Mute button */}
      <div className="flex gap-1 mb-1">
        <SendMuteButton
          trackIndex={trackIndex}
          destTrackIdx={destTrackIdx}
          isSelected={isSelected}
        />
      </div>

      {/* Destination name */}
      <div
        className="w-full text-center text-[10px] text-sends-primary truncate px-1 pb-1"
        title={`Send to: ${destName}`}
      >
        → {destName}
      </div>

      {/* Selection footer - separate visual area */}
      {onSelectForInfo && (
        <div className="w-full mt-1 pt-2 pb-2 bg-bg-deep rounded-b-lg border-t border-sends-border flex justify-center">
          <button
            onClick={() => onSelectForInfo(trackIndex)}
            className={`w-5 h-5 rounded-full border-2 transition-colors ${
              isInfoSelected
                ? 'border-accent-region bg-accent-region'
                : 'border-text-tertiary hover:border-text-secondary bg-transparent'
            }`}
            title="Select for info"
            aria-pressed={isInfoSelected}
          >
            {isInfoSelected && (
              <div className="w-2.5 h-2.5 rounded-full bg-white mx-auto" />
            )}
          </button>
        </div>
      )}
    </div>
  );
}
