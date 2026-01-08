/**
 * RecordingIndicator - Pulsing recording indicator
 * Only rendered when recording is active
 */

import { type ReactElement } from 'react';
import { useTransport } from '../../../hooks';

export function RecordingIndicator(): ReactElement | null {
  const { isRecording } = useTransport();

  if (!isRecording) {
    return null;
  }

  return (
    <div
      className="flex items-center text-red-400 font-medium"
      style={{
        marginTop: 'clamp(0.5rem, 2cqh, 2rem)',
        gap: 'clamp(0.375rem, 1cqh, 0.75rem)',
        fontSize: 'clamp(0.875rem, 4cqh, 1.875rem)',
      }}
    >
      <div
        className="rounded-full bg-red-500 animate-pulse"
        style={{
          width: 'clamp(10px, 2cqh, 20px)',
          height: 'clamp(10px, 2cqh, 20px)',
        }}
      />
      <span>RECORDING</span>
    </div>
  );
}
