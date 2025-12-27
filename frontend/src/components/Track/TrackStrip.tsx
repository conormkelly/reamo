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
import { Fader } from './Fader';
import { PanKnob } from './PanKnob';

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
  // Top border always uses track color for emphasis, sides/bottom use subtle border
  const topBorderColor = color || '#6b7280';
  const sideBorderColor = isSelected ? (color || '#6b7280') : '#374151';
  const backgroundColor = isSelected ? '#374151' : '#1f2937';

  // Master track has squared top with subtle bottom radius, other tracks have full rounded corners
  const isMaster = trackIndex === 0;
  const roundedClass = isMaster ? 'rounded-b-md' : 'rounded-lg';

  return (
    <div
      className={`flex flex-col items-center p-2 ${roundedClass} border min-w-[80px] select-none ${className}`}
      style={{
        backgroundColor,
        borderLeftColor: sideBorderColor,
        borderRightColor: sideBorderColor,
        borderBottomColor: sideBorderColor,
        borderTopWidth: '5px',
        borderTopColor: topBorderColor,
      }}
    >
      {/* Track name - tap to toggle, long-press for exclusive select */}
      <div
        className="w-full text-center text-sm font-medium truncate mb-2 px-1 cursor-pointer"
        title={name}
        style={color ? { color } : undefined}
        {...longPressHandlers}
      >
        {trackIndex === 0 ? 'Master' : name || `Track ${trackIndex}`}
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

      {/* Record controls (not on master) */}
      {trackIndex !== 0 && (
        <div className="flex gap-1">
          <RecordArmButton trackIndex={trackIndex} isSelected={isSelected} />
          <MonitorButton trackIndex={trackIndex} isSelected={isSelected} />
        </div>
      )}
    </div>
  );
}
