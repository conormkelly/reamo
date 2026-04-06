/**
 * TransportBar Component
 * Icon-only transport controls matching REAPER's native layout
 */

import type { ReactElement } from 'react';
import { SkipBack, Play, Pause, Repeat, Square } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import { useReaperStore } from '../../store';
import { useRecordButton } from '../../hooks/useRecordButton';
import { transport } from '../../core/WebSocketCommands';
import { CircularTransportButton } from './CircularTransportButton';
import { RecordModeIcon } from './RecordModeIcon';
import { recordModeTitle } from '../../hooks/useRecordButton';

export interface TransportBarProps {
  className?: string;
}

/**
 * Icon-only transport bar matching REAPER's native transport layout
 * Order: Skip to Start | Play | Pause | Loop | Stop | Record
 */
export function TransportBar({ className = '' }: TransportBarProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop, toggleRepeat } = useTransport();
  const isRepeat = useReaperStore((state) => state.isRepeat);
  const { pointerHandlers, recordMode } = useRecordButton();

  const handleSkipToStart = () => sendCommand(transport.goStart());
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleRepeat = () => sendCommand(toggleRepeat());
  const handleStop = () => sendCommand(stop());

  const recordInactiveClass = recordMode !== 'normal'
    ? 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring'
    : 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring-dim';

  // Announce recording state changes to screen readers
  const recordingStatusText = isRecording
    ? 'Recording started'
    : isPlaying
      ? 'Playing'
      : isStopped
        ? 'Stopped'
        : isPaused
          ? 'Paused'
          : '';

  return (
    <div className={`flex items-center justify-center gap-2 ${className}`}>
      {/* Visually hidden live region for screen readers */}
      <span className="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {recordingStatusText}
      </span>

      {/* Skip to Start */}
      <CircularTransportButton onClick={handleSkipToStart} title="Skip to Start">
        <SkipBack size={20} />
      </CircularTransportButton>

      {/* Play */}
      <CircularTransportButton
        onClick={handlePlay}
        isActive={isPlaying}
        activeColor="green"
        title="Play"
      >
        <Play size={20} fill={isPlaying ? 'currentColor' : 'none'} />
      </CircularTransportButton>

      {/* Pause */}
      <CircularTransportButton
        onClick={handlePause}
        isActive={isPaused}
        activeColor="gray"
        title="Pause"
      >
        <Pause size={20} fill={isPaused ? 'currentColor' : 'none'} />
      </CircularTransportButton>

      {/* Loop/Repeat */}
      <CircularTransportButton
        onClick={handleRepeat}
        isActive={isRepeat}
        activeColor="green"
        title="Toggle Loop"
      >
        <Repeat size={20} />
      </CircularTransportButton>

      {/* Stop */}
      <CircularTransportButton
        onClick={handleStop}
        isActive={isStopped}
        activeColor="gray"
        title="Stop"
      >
        <Square size={18} fill={isStopped ? 'currentColor' : 'none'} />
      </CircularTransportButton>

      {/* Record - with long-press for record mode cycling */}
      <button
        {...pointerHandlers}
        title={recordModeTitle(recordMode)}
        aria-label={recordModeTitle(recordMode)}
        aria-pressed={isRecording}
        className={`
          w-11 h-11 rounded-full flex items-center justify-center
          transition-colors touch-none
          ${isRecording ? 'bg-error animate-pulse' : recordInactiveClass}
        `}
      >
        <RecordModeIcon mode={recordMode} size={20} />
      </button>
    </div>
  );
}
