/**
 * HardwareTab - Tab content for hardware output routing controls
 * Renders a list of HorizontalRoutingFader components for each hardware output.
 */

import { useState, type ReactElement } from 'react';
import { useReaper } from '../../../hooks/useReaper';
import { useTrack } from '../../../hooks/useTrack';
import { hw as hwCmd, gesture } from '../../../core/WebSocketCommands';
import { HorizontalRoutingFader } from './HorizontalRoutingFader';
import { useGestureGuid } from './useGestureGuid';
import { HwChannelPicker } from './HwChannelPicker';
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
  trackGuid: string;
  hwOutputs: HwOutputData[];
  hwOutCount: number;
}

/** Individual hardware output row */
function HwOutputRow({
  trackIndex,
  trackGuid,
  hw,
  onLabelTap,
}: {
  trackIndex: number;
  trackGuid: string;
  hw: HwOutputData;
  onLabelTap: () => void;
}): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const volumeGuid = useGestureGuid(guid);
  const panGuid = useGestureGuid(guid);
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
      onLabelTap={onLabelTap}
      onVolumeChange={(volume) => {
        sendCommand(hwCmd.setVolume(trackIndex, hwIdx, volume, volumeGuid.current()));
      }}
      onVolumeGestureStart={() => {
        const g = volumeGuid.begin();
        if (!g) return;
        sendCommand(gesture.start('hwOutputVolume', trackIndex, g, undefined, hwIdx));
      }}
      onVolumeGestureEnd={() => {
        const g = volumeGuid.end();
        if (!g) return;
        sendCommand(gesture.end('hwOutputVolume', trackIndex, g, undefined, hwIdx));
      }}
      onVolumeDoubleTap={() => {
        sendCommand(hwCmd.setVolume(trackIndex, hwIdx, 1.0, guid));
      }}
      onPanChange={(pan) => {
        sendCommand(hwCmd.setPan(trackIndex, hwIdx, pan, panGuid.current()));
      }}
      onPanGestureStart={() => {
        const g = panGuid.begin();
        if (!g) return;
        sendCommand(gesture.start('hwOutputPan', trackIndex, g, undefined, hwIdx));
      }}
      onPanGestureEnd={() => {
        const g = panGuid.end();
        if (!g) return;
        sendCommand(gesture.end('hwOutputPan', trackIndex, g, undefined, hwIdx));
      }}
      onPanDoubleTap={() => {
        sendCommand(hwCmd.setPan(trackIndex, hwIdx, 0, guid));
      }}
      onMuteToggle={() => {
        sendCommand(hwCmd.setMute(trackIndex, hwIdx, hw.muted ? 0 : 1, guid));
      }}
      onModeToggle={() => {
        sendCommand(hwCmd.setMode(trackIndex, hwIdx, nextMode(hw.mode), guid));
      }}
      onDelete={() => {
        sendCommand(hwCmd.remove(trackGuid, hwIdx));
      }}
    />
  );
}

export function HardwareTab({ trackIndex, trackGuid, hwOutputs, hwOutCount }: HardwareTabProps): ReactElement {
  const { sendCommand, sendCommandAsync } = useReaper();
  // 'create' = picking channel for new hw output, number = editing existing hw output's dest
  const [pickerMode, setPickerMode] = useState<'create' | number | null>(null);

  // Show picker for creating or editing
  if (pickerMode !== null) {
    const isEditing = typeof pickerMode === 'number';
    const editingHw = isEditing ? hwOutputs.find((h) => h.hwIdx === pickerMode) : undefined;

    return (
      <HwChannelPicker
        prompt={isEditing ? 'Change output destination' : 'Choose output destination'}
        currentDestChannel={editingHw?.destChannel}
        onSelect={async (destChannel) => {
          if (isEditing) {
            sendCommand(hwCmd.setDestChannel(trackIndex, pickerMode, destChannel, trackGuid));
          } else {
            // Create new hw output, then set its destination
            try {
              const res = (await sendCommandAsync(hwCmd.add(trackGuid))) as {
                success?: boolean;
                payload?: { hwIdx?: number };
              };
              if (res.success && res.payload?.hwIdx !== undefined) {
                sendCommand(hwCmd.setDestChannel(trackIndex, res.payload.hwIdx, destChannel, trackGuid));
              }
            } catch {
              // hw/add may fail silently — output still created with defaults by REAPER
            }
          }
          setPickerMode(null);
        }}
        onCancel={() => setPickerMode(null)}
      />
    );
  }

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
      <div className="text-center py-8">
        <p className="text-text-muted">No hardware outputs on this track</p>
        <button
          onClick={() => setPickerMode('create')}
          className="mt-3 text-sm text-accent-primary hover:text-accent-hover"
        >
          + Add Hardware Output
        </button>
      </div>
    );
  }

  return (
    <>
      {hwOutputs.map((hw) => (
        <HwOutputRow
          key={hw.hwIdx}
          trackIndex={trackIndex}
          trackGuid={trackGuid}
          hw={hw}
          onLabelTap={() => setPickerMode(hw.hwIdx)}
        />
      ))}
      <button
        onClick={() => setPickerMode('create')}
        className="w-full mt-2 py-2 text-sm text-accent-primary hover:text-accent-hover rounded-lg hover:bg-bg-elevated transition-colors"
      >
        + Add Hardware Output
      </button>
    </>
  );
}
