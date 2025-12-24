/**
 * TransportBar Component
 * Icon-only transport controls matching REAPER's native layout
 */

import { useRef, useCallback, type ReactElement } from 'react';
import { SkipBack, Play, Pause, Repeat, Square, Circle, RefreshCw } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import { useReaperStore } from '../../store';
import { transport, action } from '../../core/WebSocketCommands';

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;

export interface TransportBarProps {
  className?: string;
}

interface TransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  inactiveClass?: string;
  title: string;
  children: React.ReactNode;
  pulse?: boolean;
}

function TransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  inactiveClass,
  title,
  children,
  pulse = false,
}: TransportButtonProps): ReactElement {
  const colorClasses = {
    green: 'bg-green-500',
    red: 'bg-red-500',
    gray: 'bg-gray-500',
  };

  const defaultInactiveClass = 'bg-gray-700 hover:bg-gray-600';

  return (
    <button
      onClick={onClick}
      title={title}
      className={`
        w-11 h-11 rounded-full flex items-center justify-center
        transition-colors
        ${isActive ? colorClasses[activeColor] : (inactiveClass || defaultInactiveClass)}
        ${pulse ? 'animate-pulse' : ''}
      `}
    >
      {children}
    </button>
  );
}

/**
 * Icon-only transport bar matching REAPER's native transport layout
 * Order: Skip to Start | Play | Pause | Loop | Stop | Record
 */
export function TransportBar({ className = '' }: TransportBarProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop, record, toggleRepeat } = useTransport();
  const isRepeat = useReaperStore((state) => state.isRepeat);
  const isAutoPunch = useReaperStore((state) => state.isAutoPunch);

  // Long-press state for Record button
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

  const handleSkipToStart = () => sendCommand(transport.goStart());
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleRepeat = () => sendCommand(toggleRepeat());
  const handleStop = () => sendCommand(stop());

  // Record button long-press handlers
  const handleRecordPointerDown = useCallback(() => {
    wasHoldRef.current = false;
    holdTimerRef.current = setTimeout(() => {
      wasHoldRef.current = true;
      // Toggle between normal and auto-punch mode
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
    // If it wasn't a hold, toggle record
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

  // Determine record button styling based on auto-punch mode
  const recordInactiveClass = isAutoPunch
    ? 'bg-red-900/30 hover:bg-red-800/50 ring-2 ring-red-500/50'
    : 'bg-red-900/30 hover:bg-red-800/50 ring-2 ring-red-500/30';

  return (
    <div className={`flex items-center justify-center gap-2 ${className}`}>
      {/* Skip to Start */}
      <TransportButton onClick={handleSkipToStart} title="Skip to Start">
        <SkipBack size={20} />
      </TransportButton>

      {/* Play */}
      <TransportButton
        onClick={handlePlay}
        isActive={isPlaying}
        activeColor="green"
        title="Play"
      >
        <Play size={20} fill={isPlaying ? 'currentColor' : 'none'} />
      </TransportButton>

      {/* Pause */}
      <TransportButton
        onClick={handlePause}
        isActive={isPaused}
        activeColor="gray"
        title="Pause"
      >
        <Pause size={20} fill={isPaused ? 'currentColor' : 'none'} />
      </TransportButton>

      {/* Loop/Repeat */}
      <TransportButton
        onClick={handleRepeat}
        isActive={isRepeat}
        activeColor="green"
        title="Toggle Loop"
      >
        <Repeat size={20} />
      </TransportButton>

      {/* Stop */}
      <TransportButton
        onClick={handleStop}
        isActive={isStopped}
        activeColor="gray"
        title="Stop"
      >
        <Square size={18} fill={isStopped ? 'currentColor' : 'none'} />
      </TransportButton>

      {/* Record - with long-press for auto-punch toggle */}
      <button
        onPointerDown={handleRecordPointerDown}
        onPointerUp={handleRecordPointerUp}
        onPointerCancel={handleRecordPointerCancel}
        onPointerLeave={handleRecordPointerCancel}
        title={isAutoPunch ? "Record (Auto-Punch) - hold to toggle mode" : "Record - hold to toggle auto-punch"}
        className={`
          w-11 h-11 rounded-full flex items-center justify-center
          transition-colors touch-none select-none
          ${isRecording ? 'bg-red-500 animate-pulse' : recordInactiveClass}
        `}
      >
        {isAutoPunch ? (
          <RefreshCw size={20} strokeWidth={2.5} />
        ) : (
          <Circle size={20} fill="currentColor" />
        )}
      </button>
    </div>
  );
}
