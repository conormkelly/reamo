/**
 * Track Strip Component
 * A complete track channel strip with fader, pan, and buttons
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { MuteButton } from './MuteButton';
import { SoloButton } from './SoloButton';
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
  const { exists, name, color, isRecordArmed } = useTrack(trackIndex);

  if (!exists) {
    return null;
  }

  return (
    <div
      className={`flex flex-col items-center p-2 bg-gray-900 rounded-lg border border-gray-700 min-w-[80px] ${className}`}
      style={color ? { borderColor: color } : undefined}
    >
      {/* Track name */}
      <div
        className="w-full text-center text-sm font-medium truncate mb-2 px-1"
        title={name}
        style={color ? { color } : undefined}
      >
        {trackIndex === 0 ? 'Master' : name || `Track ${trackIndex}`}
      </div>

      {/* Fader */}
      {showFader && <Fader trackIndex={trackIndex} className="mb-2" />}

      {/* Pan */}
      {showPan && <PanKnob trackIndex={trackIndex} className="mb-2" />}

      {/* Buttons */}
      <div className="flex gap-1">
        <MuteButton trackIndex={trackIndex} />
        <SoloButton trackIndex={trackIndex} />
      </div>

      {/* Record arm indicator */}
      {isRecordArmed && (
        <div className="mt-2 w-3 h-3 rounded-full bg-red-500 animate-pulse" />
      )}
    </div>
  );
}
