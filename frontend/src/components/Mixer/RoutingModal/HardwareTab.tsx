/**
 * HardwareTab - Tab content for hardware output routing controls
 * Renders a list of HorizontalRoutingFader components for each hardware output.
 */

import { type ReactElement } from 'react';
import { useReaper } from '../../ReaperProvider';
import { useTrack } from '../../../hooks/useTrack';
import { hw as hwCmd, gesture } from '../../../core/WebSocketCommands';
import { HorizontalRoutingFader } from './HorizontalRoutingFader';
import { nextMode, formatHwOutputName } from './routingUtils';

export interface HwOutputData {
  hwIdx: number;
  destChannel: number;
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
}

export interface HardwareTabProps {
  trackIndex: number;
  hwOutputs: HwOutputData[];
  hwOutCount: number;
}

/** Individual hardware output row */
function HwOutputRow({
  trackIndex,
  hw,
}: {
  trackIndex: number;
  hw: HwOutputData;
}): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const hwIdx = hw.hwIdx;
  const label = formatHwOutputName(hw.destChannel);

  return (
    <HorizontalRoutingFader
      volume={hw.volume}
      pan={hw.pan}
      muted={hw.muted}
      mode={hw.mode}
      label={label}
      colorScheme="hardware"
      onVolumeChange={(volume) => {
        sendCommand(hwCmd.setVolume(trackIndex, hwIdx, volume));
      }}
      onVolumeGestureStart={() => {
        if (!guid) return;
        sendCommand(gesture.start('hwOutputVolume', trackIndex, guid, undefined, hwIdx));
      }}
      onVolumeGestureEnd={() => {
        if (!guid) return;
        sendCommand(gesture.end('hwOutputVolume', trackIndex, guid, undefined, hwIdx));
      }}
      onVolumeDoubleTap={() => {
        sendCommand(hwCmd.setVolume(trackIndex, hwIdx, 1.0));
      }}
      onPanChange={(pan) => {
        sendCommand(hwCmd.setPan(trackIndex, hwIdx, pan));
      }}
      onPanGestureStart={() => {
        if (!guid) return;
        sendCommand(gesture.start('hwOutputPan', trackIndex, guid, undefined, hwIdx));
      }}
      onPanGestureEnd={() => {
        if (!guid) return;
        sendCommand(gesture.end('hwOutputPan', trackIndex, guid, undefined, hwIdx));
      }}
      onPanDoubleTap={() => {
        sendCommand(hwCmd.setPan(trackIndex, hwIdx, 0));
      }}
      onMuteToggle={() => {
        sendCommand(hwCmd.setMute(trackIndex, hwIdx, hw.muted ? 0 : 1));
      }}
      onModeToggle={() => {
        sendCommand(hwCmd.setMode(trackIndex, hwIdx, nextMode(hw.mode)));
      }}
    />
  );
}

export function HardwareTab({ trackIndex, hwOutputs, hwOutCount }: HardwareTabProps): ReactElement {
  // Loading state - we know there are hw outputs but data hasn't arrived
  if (hwOutCount > 0 && hwOutputs.length === 0) {
    return (
      <div className="text-center text-text-muted py-8">
        <p>Loading hardware outputs...</p>
      </div>
    );
  }

  // Empty state
  if (hwOutputs.length === 0) {
    return (
      <div className="text-center text-text-muted py-8">
        <p>No hardware outputs on this track</p>
        <p className="text-xs mt-1">Add hardware outputs in REAPER's routing window</p>
      </div>
    );
  }

  return (
    <>
      {hwOutputs.map((hw) => (
        <HwOutputRow
          key={hw.hwIdx}
          trackIndex={trackIndex}
          hw={hw}
        />
      ))}
    </>
  );
}
