/**
 * Record Button Component
 */

import type { ReactElement } from 'react';
import { Circle } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';

export interface RecordButtonProps {
  className?: string;
}

export function RecordButton({ className = '' }: RecordButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isRecording, record } = useTransport();

  const handleClick = () => {
    sendCommand(record());
  };

  return (
    <button
      onClick={handleClick}
      className={`px-4 py-2 rounded font-medium transition-colors ${
        isRecording
          ? 'bg-error text-text-on-error animate-pulse'
          : 'bg-bg-elevated text-text-primary hover:bg-error-action'
      } ${className}`}
    >
      <Circle size={16} className="inline-block mr-1 fill-current" />
        {isRecording ? 'Recording' : 'Record'}
    </button>
  );
}
