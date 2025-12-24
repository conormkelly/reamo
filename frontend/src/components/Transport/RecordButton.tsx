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
          ? 'bg-red-500 text-white animate-pulse'
          : 'bg-gray-700 text-white hover:bg-red-600'
      } ${className}`}
    >
      <Circle size={16} className="inline-block mr-1 fill-current" />
        {isRecording ? 'Recording' : 'Record'}
    </button>
  );
}
