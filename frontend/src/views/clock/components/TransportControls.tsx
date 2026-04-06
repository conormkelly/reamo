/**
 * TransportControls - Skip, Play, Pause, Stop, Record buttons
 * Record button supports long-press to cycle record modes
 */

import type { ReactElement } from 'react';
import { Play, Pause, Square, SkipBack } from 'lucide-react';
import { useReaper } from '../../../components/ReaperProvider';
import { useTransport } from '../../../hooks';
import { useRecordButton } from '../../../hooks/useRecordButton';
import { transport } from '../../../core/WebSocketCommands';
import { RecordModeIcon } from '../../../components/Transport/RecordModeIcon';
import { recordModeTitle } from '../../../hooks/useRecordButton';

interface BigTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  title: string;
  action: string;
  children: React.ReactNode;
  scale: number;
}

function BigTransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  title,
  action,
  children,
  scale,
}: BigTransportButtonProps): ReactElement {
  const colorClasses = {
    green: 'bg-success',
    red: 'bg-error',
    gray: 'bg-bg-hover',
  };

  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      aria-pressed={isActive}
      data-testid="transport-button"
      data-action={action}
      className={`
        aspect-square rounded-full flex items-center justify-center
        transition-colors shadow-lg
        ${isActive ? colorClasses[activeColor] : 'bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled'}
      `}
      style={{
        width: `calc(clamp(48px, 12cqmin, 112px) * ${scale})`,
        height: `calc(clamp(48px, 12cqmin, 112px) * ${scale})`,
      }}
    >
      {children}
    </button>
  );
}

interface TransportControlsProps {
  scale: number;
}

export function TransportControls({ scale }: TransportControlsProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, isPaused, isStopped, play, pause, stop } = useTransport();
  const { pointerHandlers, recordMode, isRecording } = useRecordButton();

  // Transport handlers
  const handleSkipToStart = () => sendCommand(transport.goStart());
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleStop = () => sendCommand(stop());

  const recordInactiveClass = recordMode !== 'normal'
    ? 'bg-record-dim-50 hover:bg-record-hover-70 ring-2 ring-record-ring'
    : 'bg-record-dim-50 hover:bg-record-hover-70 ring-2 ring-record-ring-dim';

  // Icon size scales with button (roughly 50% of button size)
  const iconStyle = {
    width: `calc(clamp(24px, 6cqmin, 56px) * ${scale})`,
    height: `calc(clamp(24px, 6cqmin, 56px) * ${scale})`,
  };

  return (
    <div
      data-testid="transport-controls"
      className="flex items-center justify-center safe-area-x"
      style={{ gap: `calc(clamp(6px, 1.5cqmin, 32px) * ${scale})` }}
    >
      <BigTransportButton onClick={handleSkipToStart} title="Skip to Start" action="skip" scale={scale}>
        <SkipBack style={iconStyle} />
      </BigTransportButton>

      <BigTransportButton
        onClick={handlePlay}
        isActive={isPlaying}
        activeColor="green"
        title="Play"
        action="play"
        scale={scale}
      >
        <Play style={iconStyle} fill={isPlaying ? 'currentColor' : 'none'} />
      </BigTransportButton>

      <BigTransportButton
        onClick={handlePause}
        isActive={isPaused}
        activeColor="gray"
        title="Pause"
        action="pause"
        scale={scale}
      >
        <Pause style={iconStyle} fill={isPaused ? 'currentColor' : 'none'} />
      </BigTransportButton>

      <BigTransportButton
        onClick={handleStop}
        isActive={isStopped}
        activeColor="gray"
        title="Stop"
        action="stop"
        scale={scale}
      >
        <Square
          style={{
            width: `calc(clamp(20px, 5cqmin, 48px) * ${scale})`,
            height: `calc(clamp(20px, 5cqmin, 48px) * ${scale})`,
          }}
          fill={isStopped ? 'currentColor' : 'none'}
        />
      </BigTransportButton>

      {/* Record - with long-press for record mode cycling */}
      <button
        {...pointerHandlers}
        title={recordModeTitle(recordMode)}
        aria-label={recordModeTitle(recordMode)}
        aria-pressed={isRecording}
        data-testid="transport-button"
        data-action="record"
        className={`
          aspect-square rounded-full flex items-center justify-center
          transition-colors shadow-lg touch-none
          ${isRecording ? 'bg-record animate-pulse' : recordInactiveClass}
        `}
        style={{
          width: `calc(clamp(48px, 12cqmin, 112px) * ${scale})`,
          height: `calc(clamp(48px, 12cqmin, 112px) * ${scale})`,
        }}
      >
        <RecordModeIcon mode={recordMode} style={iconStyle} />
      </button>
    </div>
  );
}
