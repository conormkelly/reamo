/**
 * Stop Button Component
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';

export interface StopButtonProps {
  className?: string;
}

export function StopButton({ className = '' }: StopButtonProps): ReactElement {
  const { send } = useReaper();
  const { isStopped, stop } = useTransport();

  const handleClick = () => {
    send(stop());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-4 py-2 rounded font-medium transition-colors ${
        isStopped
          ? 'bg-gray-500 text-white'
          : 'bg-gray-700 text-white hover:bg-gray-600'
      } ${className}`}
    >
      ■ Stop
    </button>
  );
}
