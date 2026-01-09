/**
 * Play Button Component
 */

import type { ReactElement } from 'react';
import { Play } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';

export interface PlayButtonProps {
  className?: string;
}

export function PlayButton({ className = '' }: PlayButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, play } = useTransport();

  const handleClick = () => {
    sendCommand(play());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-4 py-2 rounded font-medium transition-colors ${
        isPlaying
          ? 'bg-success text-text-primary'
          : 'bg-bg-elevated text-text-primary hover:bg-bg-hover'
      } ${className}`}
    >
      <Play size={16} className="inline-block mr-1" />
        {isPlaying ? 'Playing' : 'Play'}
    </button>
  );
}
