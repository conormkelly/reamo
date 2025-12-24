/**
 * Track Strip Component
 * A complete track channel strip with fader, pan, and buttons
 * Long-press to select track for take switching
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

  // Long-press to toggle track selection
  const { handlers: longPressHandlers } = useLongPress({
    onLongPress: () => {
      // Toggle selection - omit 'selected' param to toggle
      sendCommand(track.setSelected(trackIndex));
    },
    duration: 300,
  });

  if (!exists) {
    return null;
  }

  // Determine border style: selected = blue, custom color, or default gray
  // Always set explicit inline styles to avoid conflicts with Tailwind classes
  const borderStyle = isSelected
    ? { borderColor: '#3b82f6', boxShadow: '0 0 0 2px rgba(59, 130, 246, 0.5)' }
    : { borderColor: color || '#374151', boxShadow: 'none' };

  return (
    <div
      className={`flex flex-col items-center p-2 bg-gray-900 rounded-lg border min-w-[80px] select-none ${className}`}
      style={borderStyle}
    >
      {/* Track name - long-press here to toggle selection */}
      <div
        className="w-full text-center text-sm font-medium truncate mb-2 px-1 cursor-pointer"
        title={name}
        style={color ? { color } : undefined}
        {...longPressHandlers}
      >
        {trackIndex === 0 ? 'Master' : name || `Track ${trackIndex}`}
      </div>

      {/* Fader */}
      {showFader && <Fader trackIndex={trackIndex} className="mb-2" />}

      {/* Pan */}
      {showPan && <PanKnob trackIndex={trackIndex} className="mb-2" />}

      {/* Buttons */}
      <div className="flex gap-1 mb-1">
        <MuteButton trackIndex={trackIndex} />
        <SoloButton trackIndex={trackIndex} />
      </div>

      {/* Record controls (not on master) */}
      {trackIndex !== 0 && (
        <div className="flex gap-1">
          <RecordArmButton trackIndex={trackIndex} />
          <MonitorButton trackIndex={trackIndex} />
        </div>
      )}
    </div>
  );
}
