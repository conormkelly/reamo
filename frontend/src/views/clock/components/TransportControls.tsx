/**
 * TransportControls - Skip, Play, Pause, Stop, Record buttons
 * Record button supports long-press to toggle auto-punch mode
 */

import { useRef, useCallback, useEffect, type ReactElement } from 'react';
import { Play, Pause, Square, Circle, SkipBack, RefreshCw } from 'lucide-react';
import { useReaper } from '../../../components/ReaperProvider';
import { useTransport } from '../../../hooks';
import { useReaperStore } from '../../../store';
import { transport, action } from '../../../core/WebSocketCommands';

// Hold duration for record button mode toggle
const HOLD_THRESHOLD = 300;

interface BigTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  title: string;
  children: React.ReactNode;
  scale: number;
}

function BigTransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  title,
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
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop, record } = useTransport();
  const isAutoPunch = useReaperStore((state) => state.isAutoPunch);

  // Transport handlers
  const handleSkipToStart = () => sendCommand(transport.goStart());
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleStop = () => sendCommand(stop());

  // Record button long-press handlers
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

  const handleRecordPointerDown = useCallback(() => {
    wasHoldRef.current = false;
    holdTimerRef.current = setTimeout(() => {
      wasHoldRef.current = true;
      if (isAutoPunch) {
        sendCommand(action.execute(40252)); // Set record mode to normal
      } else {
        sendCommand(action.execute(40076)); // Set record mode to time selection auto-punch
      }
    }, HOLD_THRESHOLD);
  }, [sendCommand, isAutoPunch]);

  const handleRecordPointerUp = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    if (!wasHoldRef.current) {
      sendCommand(record());
    }
  }, [sendCommand, record]);

  const handleRecordPointerCancel = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
  }, []);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
      }
    };
  }, []);

  const recordInactiveClass = isAutoPunch
    ? 'bg-record-dim-50 hover:bg-record-hover-70 ring-2 ring-record-ring'
    : 'bg-record-dim-50 hover:bg-record-hover-70 ring-2 ring-record-ring-dim';

  // Icon size scales with button (roughly 50% of button size)
  const iconStyle = {
    width: `calc(clamp(24px, 6cqmin, 56px) * ${scale})`,
    height: `calc(clamp(24px, 6cqmin, 56px) * ${scale})`,
  };

  return (
    <div
      className="flex items-center justify-center safe-area-x"
      style={{ gap: `calc(clamp(6px, 1.5cqmin, 32px) * ${scale})` }}
    >
      <BigTransportButton onClick={handleSkipToStart} title="Skip to Start" scale={scale}>
        <SkipBack style={iconStyle} />
      </BigTransportButton>

      <BigTransportButton
        onClick={handlePlay}
        isActive={isPlaying}
        activeColor="green"
        title="Play"
        scale={scale}
      >
        <Play style={iconStyle} fill={isPlaying ? 'currentColor' : 'none'} />
      </BigTransportButton>

      <BigTransportButton
        onClick={handlePause}
        isActive={isPaused}
        activeColor="gray"
        title="Pause"
        scale={scale}
      >
        <Pause style={iconStyle} fill={isPaused ? 'currentColor' : 'none'} />
      </BigTransportButton>

      <BigTransportButton
        onClick={handleStop}
        isActive={isStopped}
        activeColor="gray"
        title="Stop"
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

      {/* Record - with long-press for auto-punch toggle */}
      <button
        onPointerDown={handleRecordPointerDown}
        onPointerUp={handleRecordPointerUp}
        onPointerCancel={handleRecordPointerCancel}
        onPointerLeave={handleRecordPointerCancel}
        title={isAutoPunch ? 'Record (Auto-Punch) - hold to toggle mode' : 'Record - hold to toggle auto-punch'}
        aria-label={isAutoPunch ? 'Record (Auto-Punch mode)' : 'Record'}
        aria-pressed={isRecording}
        className={`
          aspect-square rounded-full flex items-center justify-center
          transition-colors shadow-lg touch-none select-none
          ${isRecording ? 'bg-record animate-pulse' : recordInactiveClass}
        `}
        style={{
          width: `calc(clamp(48px, 12cqmin, 112px) * ${scale})`,
          height: `calc(clamp(48px, 12cqmin, 112px) * ${scale})`,
        }}
      >
        {isAutoPunch ? (
          <RefreshCw style={iconStyle} strokeWidth={2.5} />
        ) : (
          <Circle style={iconStyle} fill="currentColor" />
        )}
      </button>
    </div>
  );
}
