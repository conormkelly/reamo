/**
 * MixerStrip Component
 * Channel strip optimized for the dedicated Mixer view.
 * Taller faders, compact layout, mode-aware rendering.
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { useReaper } from '../ReaperProvider';
import { track as trackCmd } from '../../core/WebSocketCommands';
import {
  MuteButton,
  SoloButton,
  RecordArmButton,
  MonitorButton,
  MasterMonoButton,
  Fader,
  PanKnob,
  LevelMeter,
} from '../Track';

export type MixerMode = 'volume' | 'mix' | 'sends';

export interface MixerStripProps {
  trackIndex: number;
  mode: MixerMode;
  /** Fader height in pixels */
  faderHeight?: number;
  /** Whether to show the dB label below the fader (default: true) */
  showDbLabel?: boolean;
  /** Whether this track is selected for info display (shows in TrackInfoBar) */
  isInfoSelected?: boolean;
  /** Callback when track is selected for info display */
  onSelectForInfo?: (trackIndex: number) => void;
  className?: string;
}

/**
 * Channel strip for the mixer view.
 *
 * Layout varies by mode:
 * - volume: Meter + Tall Fader + dB + M/S + Mono(master)/RecArm+Monitor(others) + Name
 * - mix: Meter + Fader + dB + Pan + M/S + RecArm + Name
 * - sends: Uses SendStrip component instead
 */
export function MixerStrip({
  trackIndex,
  mode,
  faderHeight = 180,
  showDbLabel = true,
  isInfoSelected = false,
  onSelectForInfo,
  className = '',
}: MixerStripProps): ReactElement | null {
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

  // Border styling (no longer changes based on info selection - that's shown by bottom bar)
  const borderClass = 'border border-border-subtle';

  return (
    <div
      className={`flex flex-col items-center rounded-lg ${borderClass} ${backgroundColor} ${className}`}
      style={{ width: 80 }}
      data-testid="mixer-strip"
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

      {/* Main content area - grid with fixed columns prevents meter shift during fader drag */}
      <div className="grid gap-1 px-1 pb-1" style={{ gridTemplateColumns: '12px 1fr' }}>
        {/* Level meter */}
        <LevelMeter
          trackIndex={trackIndex}
          height={faderHeight}
          showPeak={true}
        />

        {/* Fader */}
        <Fader
          trackIndex={trackIndex}
          height={faderHeight}
          isSelected={isSelected}
          showDbLabel={showDbLabel}
        />
      </div>

      {/* Pan control */}
      <PanKnob
        trackIndex={trackIndex}
        width={70}
        isSelected={isSelected}
        className="mb-1"
      />

      {/* M/S buttons */}
      <div className="flex gap-1 mb-1">
        <MuteButton trackIndex={trackIndex} isSelected={isSelected} />
        <SoloButton trackIndex={trackIndex} isSelected={isSelected} />
      </div>

      {/* Volume mode: Master gets Mono button, others get RecArm + Monitor */}
      {mode === 'volume' && (
        isMaster ? (
          <MasterMonoButton isSelected={isSelected} className="mb-1" />
        ) : (
          <div className="flex gap-1 mb-1">
            <RecordArmButton trackIndex={trackIndex} isSelected={isSelected} />
            <MonitorButton trackIndex={trackIndex} isSelected={isSelected} />
          </div>
        )
      )}

      {/* Mix mode: Record Arm (non-master only) - spacer for master to match height */}
      {mode === 'mix' && (
        isMaster ? (
          <div className="h-[26px] mb-1" /> // Spacer to match RecordArmButton height
        ) : (
          <RecordArmButton
            trackIndex={trackIndex}
            isSelected={isSelected}
            className="mb-1"
          />
        )
      )}

      {/* Selection footer - solid bar when selected */}
      {onSelectForInfo && (
        <button
          onClick={() => onSelectForInfo(trackIndex)}
          className={`w-full h-4 rounded-b-lg transition-colors ${
            isInfoSelected
              ? 'bg-primary'
              : 'bg-bg-deep hover:bg-bg-elevated border-t border-border-subtle'
          }`}
          title="Select for info"
          aria-pressed={isInfoSelected}
        />
      )}
    </div>
  );
}
