/**
 * ReceivesTab - Tab content for receive routing controls
 * Renders a list of HorizontalRoutingFader components for each receive.
 */

import { useState, type ReactElement } from 'react';
import { useReaper } from '../../ReaperProvider';
import { useTrack } from '../../../hooks/useTrack';
import { receive as receiveCmd, gesture } from '../../../core/WebSocketCommands';
import { HorizontalRoutingFader } from './HorizontalRoutingFader';
import { TrackPicker } from './TrackPicker';
import { nextMode } from './routingUtils';

export interface ReceiveData {
  srcTrackIdx: number;
  destTrackIdx: number;
  sendIndex: number; // This is the receive index from the perspective of the destination track
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
  srcName: string;
}

export interface ReceivesTabProps {
  trackIndex: number;
  trackGuid: string;
  receives: ReceiveData[];
  trackNameLookup: Record<number, string>;
}

/** Individual receive row - each maintains its own gesture tracking */
function ReceiveRow({
  trackIndex,
  trackGuid,
  recv,
  label,
}: {
  trackIndex: number;
  trackGuid: string;
  recv: ReceiveData;
  label: string;
}): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const recvIdx = recv.sendIndex;

  return (
    <HorizontalRoutingFader
      volume={recv.volume}
      pan={recv.pan ?? 0}
      muted={recv.muted}
      mode={recv.mode ?? 0}
      label={label}
      colorScheme="receive"
      onVolumeChange={(volume) => {
        sendCommand(receiveCmd.setVolume(trackIndex, recvIdx, volume));
      }}
      onVolumeGestureStart={() => {
        if (!guid) return;
        sendCommand(gesture.start('receive', trackIndex, guid, undefined, undefined, recvIdx));
      }}
      onVolumeGestureEnd={() => {
        if (!guid) return;
        sendCommand(gesture.end('receive', trackIndex, guid, undefined, undefined, recvIdx));
      }}
      onVolumeDoubleTap={() => {
        sendCommand(receiveCmd.setVolume(trackIndex, recvIdx, 1.0));
      }}
      onPanChange={(pan) => {
        sendCommand(receiveCmd.setPan(trackIndex, recvIdx, pan));
      }}
      onPanGestureStart={() => {
        if (!guid) return;
        sendCommand(gesture.start('receivePan', trackIndex, guid, undefined, undefined, recvIdx));
      }}
      onPanGestureEnd={() => {
        if (!guid) return;
        sendCommand(gesture.end('receivePan', trackIndex, guid, undefined, undefined, recvIdx));
      }}
      onPanDoubleTap={() => {
        sendCommand(receiveCmd.setPan(trackIndex, recvIdx, 0));
      }}
      onMuteToggle={() => {
        sendCommand(receiveCmd.setMute(trackIndex, recvIdx, recv.muted ? 0 : 1));
      }}
      onModeToggle={() => {
        sendCommand(receiveCmd.setMode(trackIndex, recvIdx, nextMode(recv.mode ?? 0)));
      }}
      onDelete={() => {
        sendCommand(receiveCmd.remove(trackGuid, recvIdx));
      }}
    />
  );
}

export function ReceivesTab({ trackIndex, trackGuid, receives, trackNameLookup }: ReceivesTabProps): ReactElement {
  const { sendCommand } = useReaper();
  const [showPicker, setShowPicker] = useState(false);

  if (showPicker) {
    return (
      <TrackPicker
        prompt="Choose source track"
        excludeGuid={trackGuid}
        onSelect={(srcGuid) => {
          sendCommand(receiveCmd.add(trackGuid, srcGuid));
          setShowPicker(false);
        }}
        onCancel={() => setShowPicker(false)}
      />
    );
  }

  if (receives.length === 0) {
    return (
      <div className="text-center py-8">
        <p className="text-text-muted">No receives to this track</p>
        <button
          onClick={() => setShowPicker(true)}
          className="mt-3 text-sm text-accent-primary hover:text-accent-hover"
        >
          + Add Receive
        </button>
      </div>
    );
  }

  return (
    <>
      {receives.map((recv) => {
        const label = recv.srcName || trackNameLookup[recv.srcTrackIdx] || `Track ${recv.srcTrackIdx}`;
        return (
          <ReceiveRow
            key={`recv-${recv.sendIndex}`}
            trackIndex={trackIndex}
            trackGuid={trackGuid}
            recv={recv}
            label={label}
          />
        );
      })}
      <button
        onClick={() => setShowPicker(true)}
        className="w-full mt-2 py-2 text-sm text-accent-primary hover:text-accent-hover rounded-lg hover:bg-bg-elevated transition-colors"
      >
        + Add Receive
      </button>
    </>
  );
}
