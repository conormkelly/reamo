/**
 * Stop Button Component
 */

import type { ReactElement } from 'react';
import { Square } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';

export interface StopButtonProps {
  className?: string;
}

export function StopButton({ className = '' }: StopButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isStopped, stop } = useTransport();

  const handleClick = () => {
    sendCommand(stop());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-4 py-2 rounded font-medium transition-colors ${
        isStopped
          ? 'bg-bg-disabled text-text-primary'
          : 'bg-bg-elevated text-text-primary hover:bg-bg-hover'
      } ${className}`}
    >
      <Square size={16} className="inline-block mr-1" />
        Stop
    </button>
  );
}
