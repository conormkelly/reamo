/**
 * SendStrip Component
 * Channel strip for Sends mode - gold faders controlling send levels.
 * Shows send level to the selected destination for each track.
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
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
  className = '',
}: SendStripProps): ReactElement | null {
  const { exists, name, isSelected, color } = useTrack(trackIndex);

  if (!exists) {
    return null;
  }

  // Master track (index 0) styling
  const isMaster = trackIndex === 0;

  // Get background color based on selection
  const backgroundColor = isSelected ? 'bg-bg-elevated' : 'bg-bg-surface';

  // Color bar styling
  const topBarColor = color || 'var(--color-text-muted)';

  return (
    <div
      className={`flex flex-col items-center rounded-lg border border-amber-500/30 ${backgroundColor} ${className}`}
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

      {/* Track name */}
      <div
        className="w-full text-center text-xs font-medium truncate px-1 py-1"
        title={name}
        style={color ? { color } : undefined}
      >
        {isMaster ? 'MASTER' : name || `Trk ${trackIndex}`}
      </div>

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
        className="w-full text-center text-[10px] text-amber-500 truncate px-1 pb-1"
        title={`Send to: ${destName}`}
      >
        → {destName}
      </div>
    </div>
  );
}
