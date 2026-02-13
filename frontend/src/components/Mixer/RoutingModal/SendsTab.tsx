/**
 * SendsTab - Tab content for send routing controls
 * Renders a list of HorizontalRoutingFader components for each send.
 */

import { type ReactElement } from 'react';
import { useReaper } from '../../ReaperProvider';
import { useTrack } from '../../../hooks/useTrack';
import { send as sendCmd, gesture } from '../../../core/WebSocketCommands';
import { HorizontalRoutingFader } from './HorizontalRoutingFader';
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
  sends: SendData[];
  trackNameLookup: Record<number, string>;
}

/** Individual send row - each maintains its own gesture refs */
function SendRow({
  trackIndex,
  send,
  label,
}: {
  trackIndex: number;
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
    />
  );
}

export function SendsTab({ trackIndex, sends, trackNameLookup }: SendsTabProps): ReactElement {
  if (sends.length === 0) {
    return (
      <div className="text-center text-text-muted py-8">
        <p>No sends from this track</p>
        <p className="text-xs mt-1">Add sends in REAPER's routing window</p>
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
            send={send}
            label={label}
          />
        );
      })}
    </>
  );
}
