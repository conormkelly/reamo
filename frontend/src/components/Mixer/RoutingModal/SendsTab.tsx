/**
 * SendsTab - Tab content for send routing controls
 * Renders a list of HorizontalRoutingFader components for each send.
 */

import { useState, type ReactElement } from 'react';
import { useReaper } from '../../ReaperProvider';
import { useTrack } from '../../../hooks/useTrack';
import { send as sendCmd, gesture } from '../../../core/WebSocketCommands';
import { HorizontalRoutingFader } from './HorizontalRoutingFader';
import { TrackPicker } from './TrackPicker';
import { nextMode } from './routingUtils';

export interface SendData {
  srcTrackIdx: number;
  destTrackIdx: number;
  sendIndex: number;
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
  destName: string;
}

export interface SendsTabProps {
  trackIndex: number;
  trackGuid: string;
  sends: SendData[];
  trackNameLookup: Record<number, string>;
}

/** Individual send row - each maintains its own gesture refs */
function SendRow({
  trackIndex,
  trackGuid,
  send,
  label,
}: {
  trackIndex: number;
  trackGuid: string;
  send: SendData;
  label: string;
}): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const sendIndex = send.sendIndex;

  return (
    <HorizontalRoutingFader
      volume={send.volume}
      pan={send.pan}
      muted={send.muted}
      mode={send.mode}
      label={label}
      colorScheme="send"
      onVolumeChange={(volume) => {
        sendCommand(sendCmd.setVolume(trackIndex, sendIndex, volume));
      }}
      onVolumeGestureStart={() => {
        if (!guid) return;
        sendCommand(gesture.start('send', trackIndex, guid, sendIndex));
      }}
      onVolumeGestureEnd={() => {
        if (!guid) return;
        sendCommand(gesture.end('send', trackIndex, guid, sendIndex));
      }}
      onVolumeDoubleTap={() => {
        sendCommand(sendCmd.setVolume(trackIndex, sendIndex, 1.0));
      }}
      onPanChange={(pan) => {
        sendCommand(sendCmd.setPan(trackIndex, sendIndex, pan));
      }}
      onPanGestureStart={() => {
        if (!guid) return;
        sendCommand(gesture.start('sendPan', trackIndex, guid, sendIndex));
      }}
      onPanGestureEnd={() => {
        if (!guid) return;
        sendCommand(gesture.end('sendPan', trackIndex, guid, sendIndex));
      }}
      onPanDoubleTap={() => {
        sendCommand(sendCmd.setPan(trackIndex, sendIndex, 0));
      }}
      onMuteToggle={() => {
        sendCommand(sendCmd.setMute(trackIndex, sendIndex, send.muted ? 0 : 1));
      }}
      onModeToggle={() => {
        sendCommand(sendCmd.setMode(trackIndex, sendIndex, nextMode(send.mode)));
      }}
      onDelete={() => {
        sendCommand(sendCmd.remove(trackGuid, sendIndex));
      }}
    />
  );
}

export function SendsTab({ trackIndex, trackGuid, sends, trackNameLookup }: SendsTabProps): ReactElement {
  const { sendCommand } = useReaper();
  const [showPicker, setShowPicker] = useState(false);

  if (showPicker) {
    return (
      <TrackPicker
        prompt="Choose destination track"
        excludeGuid={trackGuid}
        onSelect={(destGuid) => {
          sendCommand(sendCmd.add(trackGuid, destGuid));
          setShowPicker(false);
        }}
        onCancel={() => setShowPicker(false)}
      />
    );
  }

  if (sends.length === 0) {
    return (
      <div className="text-center py-8">
        <p className="text-text-muted">No sends from this track</p>
        <button
          onClick={() => setShowPicker(true)}
          className="mt-3 text-sm text-accent-primary hover:text-accent-hover"
        >
          + Add Send
        </button>
      </div>
    );
  }

  return (
    <>
      {sends.map((send) => {
        const label = send.destName || trackNameLookup[send.destTrackIdx] || `Track ${send.destTrackIdx}`;
        return (
          <SendRow
            key={`${send.srcTrackIdx}-${send.sendIndex}`}
            trackIndex={trackIndex}
            trackGuid={trackGuid}
            send={send}
            label={label}
          />
        );
      })}
      <button
        onClick={() => setShowPicker(true)}
        className="w-full mt-2 py-2 text-sm text-accent-primary hover:text-accent-hover rounded-lg hover:bg-bg-elevated transition-colors"
      >
        + Add Send
      </button>
    </>
  );
}
