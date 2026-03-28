/**
 * MixerStripCompact - Enhanced compact strip for landscape mode
 *
 * Shows fader + meter + dB + pan + M/S + Rec/Mon inline on every strip,
 * matching portrait mode feature parity. Controls are compact but tappable.
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

export interface MixerStripCompactProps {
  trackIndex: number;
  /** Fader height in pixels */
  faderHeight: number;
  /** Whether this track is selected for info display */
  isInfoSelected?: boolean;
  /** Callback when track is selected for info display */
  onSelectForInfo?: (trackIndex: number) => void;
  className?: string;
}

/**
 * Compact channel strip for landscape mixer view.
 *
 * Layout (top to bottom):
 * - Color bar with track number (6px)
 * - Track name (truncated, ~20px)
 * - Meter + Fader with dB label (faderHeight + ~14px for dB)
 * - Pan knob (~20px)
 * - M/S buttons (~22px)
 * - Rec/Mon buttons (~22px)
 * - Selection footer (16px)
 *
 * Total overhead ≈ 106px (see STRIP_OVERHEAD_COMPACT in layout.ts)
 */
export function MixerStripCompact({
  trackIndex,
  faderHeight,
  isInfoSelected = false,
  onSelectForInfo,
  className = '',
}: MixerStripCompactProps): ReactElement | null {
  const { exists, name, isSelected, color, guid } = useTrack(trackIndex);
  const { sendCommand } = useReaper();

  if (!exists) {
    return null;
  }

  const isMaster = trackIndex === 0;
  const backgroundColor = isSelected ? 'bg-bg-elevated' : 'bg-bg-surface';
  const topBarColor = color || 'var(--color-text-muted)';

  // Toggle track selection in REAPER when tapping name
  const handleToggleSelectInReaper = () => {
    sendCommand(trackCmd.setSelected(trackIndex, isSelected ? 0 : 1, guid));
  };

  return (
    <div
      className={`flex flex-col items-center rounded-lg border border-border-subtle ${backgroundColor} ${className}`}
      style={{ width: 82 }}
      data-testid="mixer-strip-compact"
      data-track-index={trackIndex}
    >
      {/* Color bar with track number */}
      <div
        className="w-full h-1.5 rounded-t-lg flex items-center justify-center"
        style={{ backgroundColor: topBarColor }}
      >
        {!isMaster && (
          <span className="text-[7px] font-medium text-white/80">
            {trackIndex}
          </span>
        )}
      </div>

      {/* Track name - tappable to toggle selection in REAPER */}
      <button
        onClick={handleToggleSelectInReaper}
        className={`w-full text-center text-[10px] font-medium truncate px-1 py-0.5 hover:bg-bg-elevated/50 transition-colors ${
          isSelected ? 'bg-bg-elevated/30' : ''
        }`}
        title={`${name || (isMaster ? 'MASTER' : `Trk ${trackIndex}`)} - tap to ${isSelected ? 'deselect' : 'select'}`}
        style={color ? { color } : undefined}
      >
        {isMaster ? 'MASTER' : name || `Trk ${trackIndex}`}
      </button>

      {/* Main content: Meter + Fader with dB label */}
      {/* Grid with fixed columns prevents meter shift during fader drag */}
      <div
        className="grid gap-1 px-1"
        style={{ gridTemplateColumns: '10px 1fr' }}
      >
        <LevelMeter
          trackIndex={trackIndex}
          height={faderHeight}
          showPeak={true}
        />
        <Fader
          trackIndex={trackIndex}
          height={faderHeight}
          isSelected={isSelected}
          showDbLabel={true}
        />
      </div>

      {/* Pan control - compact */}
      <PanKnob
        trackIndex={trackIndex}
        width={68}
        isSelected={isSelected}
        className="mt-0.5 [&>span]:text-[8px]"
      />

      {/* M/S buttons */}
      <div className="flex gap-0.5 mt-0.5 px-1 w-full">
        <MuteButton trackIndex={trackIndex} isSelected={isSelected} className="!px-0 !py-0 flex-1 h-5 text-[10px] flex items-center justify-center" />
        <SoloButton trackIndex={trackIndex} isSelected={isSelected} className="!px-0 !py-0 flex-1 h-5 text-[10px] flex items-center justify-center" />
      </div>

      {/* Rec/Mon or Master Mono */}
      {isMaster ? (
        <div className="flex gap-0.5 mt-0.5 px-1 w-full mb-0.5">
          <MasterMonoButton isSelected={isSelected} className="!px-0 !py-0 flex-1 h-5 text-[10px] flex items-center justify-center" />
        </div>
      ) : (
        <div className="flex gap-0.5 mt-0.5 px-1 w-full mb-0.5">
          <RecordArmButton trackIndex={trackIndex} isSelected={isSelected} className="!px-0 !py-0 flex-1 h-5 text-[10px] flex items-center justify-center" />
          <MonitorButton trackIndex={trackIndex} isSelected={isSelected} className="!px-0 !py-0 flex-1 h-5 text-[10px] flex items-center justify-center" />
        </div>
      )}

      {/* Selection footer - solid bar when selected */}
      {onSelectForInfo && (
        <button
          onClick={() => onSelectForInfo(trackIndex)}
          className={`w-full h-3 rounded-b-lg transition-colors ${
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
