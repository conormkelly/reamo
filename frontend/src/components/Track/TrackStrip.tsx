/**
 * Track Strip Component
 * A complete track channel strip with fader, pan, and buttons
 * Tap track name to toggle selection, long-press for exclusive select
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { useLongPress } from '../../hooks/useLongPress';
import { useReaper } from '../ReaperProvider';
import { track } from '../../core/WebSocketCommands';
import { MuteButton } from './MuteButton';
import { SoloButton } from './SoloButton';
import { RecordArmButton } from './RecordArmButton';
import { MonitorButton } from './MonitorButton';
import { MasterMonoButton } from './MasterMonoButton';
import { Fader } from './Fader';
import { PanKnob } from './PanKnob';
/** Get contrasting text color (black or white) for a hex color */
function getContrastFromHex(hex: string | null): 'black' | 'white' {
  if (!hex) return 'white';
  // Parse hex to RGB
  const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
  if (!result) return 'white';
  const r = parseInt(result[1], 16);
  const g = parseInt(result[2], 16);
  const b = parseInt(result[3], 16);
  // Calculate luminance
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return luminance > 0.5 ? 'black' : 'white';
}

export interface TrackStripProps {
  trackIndex: number;
  className?: string;
  showFader?: boolean;
  showPan?: boolean;
}

export function TrackStrip({
  trackIndex,
  className = '',
  showFader = true,
  showPan = true,
}: TrackStripProps): ReactElement | null {
  const { exists, name, color, isSelected } = useTrack(trackIndex);
  const { sendCommand } = useReaper();

  // Tap to toggle selection, long-press for exclusive select
  const { handlers: longPressHandlers } = useLongPress({
    onTap: () => {
      // Toggle selection - omit 'selected' param to toggle
      sendCommand(track.setSelected(trackIndex));
    },
    onLongPress: () => {
      // Exclusive select - unselect all, then select this one
      sendCommand(track.unselectAll());
      sendCommand(track.setSelected(trackIndex, 1));
    },
    duration: 400,
  });

  if (!exists) {
    return null;
  }

  // Determine style: selected = brighter background
  // color is already a hex string from useTrack
  const defaultColor = 'var(--color-text-muted)';
  const topBarColor = color || defaultColor;
  const sideBorderColor = isSelected ? (color || defaultColor) : 'var(--color-bg-elevated)';
  const backgroundColor = isSelected ? 'var(--color-bg-elevated)' : 'var(--color-bg-surface)';

  // Master track has squared top with subtle bottom radius, other tracks have full rounded corners
  const isMaster = trackIndex === 0;
  const roundedClass = isMaster ? 'rounded-b-md' : 'rounded-lg';
  const topRoundedClass = isMaster ? '' : 'rounded-t-lg';

  // Get contrasting text color for the track number
  const trackNumberColor = getContrastFromHex(color);

  return (
    <div
      className={`flex flex-col items-center ${roundedClass} border border-t-0 w-[100px] ${className}`}
      style={{
        backgroundColor,
        borderLeftColor: sideBorderColor,
        borderRightColor: sideBorderColor,
        borderBottomColor: sideBorderColor,
      }}
      data-testid="track-strip"
      data-track-index={trackIndex}
      data-selected={isSelected}
      data-master={isMaster}
    >
      {/* Color bar with track number */}
      <div
        className={`w-full h-2.5 flex items-center justify-center ${topRoundedClass}`}
        style={{ backgroundColor: topBarColor }}
        data-testid="track-color-bar"
      >
        {!isMaster && (
          <span
            className="text-[9px] font-medium leading-none"
            style={{ color: trackNumberColor }}
            data-testid="track-number"
          >
            {trackIndex}
          </span>
        )}
      </div>

      {/* Main content */}
      <div className="flex flex-col items-center p-2 w-full">
      {/* Track name - tap to toggle, long-press for exclusive select */}
      <div
        className="w-full text-center text-sm font-medium truncate mb-2 px-1 cursor-pointer"
        title={name}
        style={color ? { color } : undefined}
        data-testid="track-name"
        {...longPressHandlers}
      >
        {trackIndex === 0 ? 'MASTER' : name || `Track ${trackIndex}`}
      </div>

      {/* Fader */}
      {showFader && <Fader trackIndex={trackIndex} className="mb-2" isSelected={isSelected} />}

      {/* Pan */}
      {showPan && <PanKnob trackIndex={trackIndex} className="mb-2" isSelected={isSelected} />}

      {/* Buttons */}
      <div className="flex gap-1 mb-1">
        <MuteButton trackIndex={trackIndex} isSelected={isSelected} />
        <SoloButton trackIndex={trackIndex} isSelected={isSelected} />
      </div>

      {/* Master: mono/stereo toggle, centered below M/S */}
      {isMaster && (
        <div className="flex justify-center">
          <MasterMonoButton isSelected={isSelected} />
        </div>
      )}

      {/* Record controls (not on master) */}
      {!isMaster && (
        <div className="flex gap-1">
          <RecordArmButton trackIndex={trackIndex} isSelected={isSelected} />
          <MonitorButton trackIndex={trackIndex} isSelected={isSelected} />
        </div>
      )}
      </div>
    </div>
  );
}
