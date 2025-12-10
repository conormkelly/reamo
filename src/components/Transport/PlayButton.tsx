/**
 * Play Button Component
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';

export interface PlayButtonProps {
  className?: string;
}

export function PlayButton({ className = '' }: PlayButtonProps): ReactElement {
  const { send } = useReaper();
  const { isPlaying, play } = useTransport();

  const handleClick = () => {
    send(play());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-4 py-2 rounded font-medium transition-colors ${
        isPlaying
          ? 'bg-green-500 text-white'
          : 'bg-gray-700 text-white hover:bg-gray-600'
      } ${className}`}
    >
      {isPlaying ? '▶ Playing' : '▶ Play'}
    </button>
  );
}
