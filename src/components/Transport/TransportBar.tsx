/**
 * TransportBar Component
 * Icon-only transport controls matching REAPER's native layout
 */

import type { ReactElement } from 'react';
import { SkipBack, Play, Pause, Repeat, Square, Circle } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import { useReaperStore } from '../../store';
import * as commands from '../../core/CommandBuilder';

export interface TransportBarProps {
  className?: string;
}

interface TransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  title: string;
  children: React.ReactNode;
  pulse?: boolean;
}

function TransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  title,
  children,
  pulse = false,
}: TransportButtonProps): ReactElement {
  const colorClasses = {
    green: 'bg-green-500',
    red: 'bg-red-500',
    gray: 'bg-gray-500',
  };

  return (
    <button
      onClick={onClick}
      title={title}
      className={`
        w-11 h-11 rounded-full flex items-center justify-center
        transition-colors
        ${isActive ? colorClasses[activeColor] : 'bg-gray-700 hover:bg-gray-600'}
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
  const { send } = useReaper();
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop, record } = useTransport();
  const isRepeat = useReaperStore((state) => state.isRepeat);

  const handleSkipToStart = () => send(commands.action(40042));
  const handlePlay = () => send(play());
  const handlePause = () => send(pause());
  const handleRepeat = () => send(commands.toggleRepeat());
  const handleStop = () => send(stop());
  const handleRecord = () => send(record());

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

      {/* Record */}
      <TransportButton
        onClick={handleRecord}
        isActive={isRecording}
        activeColor="red"
        title="Record"
        pulse={isRecording}
      >
        <Circle size={20} fill="currentColor" />
      </TransportButton>
    </div>
  );
}
