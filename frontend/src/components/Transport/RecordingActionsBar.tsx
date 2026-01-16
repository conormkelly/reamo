/**
 * RecordingActionsBar Component
 * Quick actions visible during recording - Scrap, Retake, Keep
 */

import { type ReactElement } from 'react';
import { Trash2, RotateCcw, Check } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import { transport } from '../../core/WebSocketCommands';

export interface RecordingActionsBarProps {
  className?: string;
}

/**
 * Actions bar shown during recording for quick workflow
 * - Scrap: Stop and delete (give up on this take)
 * - Retake: Delete and immediately restart (one-tap retry)
 * - Keep: Stop and keep the take (happy with it)
 */
export function RecordingActionsBar({ className = '' }: RecordingActionsBarProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const { isRecording } = useTransport();

  // Only show when recording
  if (!isRecording) {
    return null;
  }

  const handleScrap = () => {
    // Stop and delete all recorded media
    // REAPER will return playhead to where recording started
    sendCommand(transport.stopAndDelete());
  };

  const handleRetake = () => {
    // Stop and delete all recorded media, then restart recording
    sendCommand(transport.stopAndDelete());

    // Small delay to ensure stop completes, then restart recording
    setTimeout(() => {
      sendCommand(transport.record());
    }, 50);
  };

  const handleKeep = () => {
    // Stop recording normally (keeps the take)
    sendCommand(transport.stop());
  };

  return (
    <div className={`flex flex-col items-center gap-2 mt-3 ${className}`}>
      {/* Heading */}
      <span className="text-xs text-text-secondary uppercase tracking-wider">Recording Actions</span>

      {/* Action buttons */}
      <div className="flex items-center justify-center gap-4">
      {/* Scrap - destructive */}
      <button
        onClick={handleScrap}
        title="Stop recording and delete this take"
        className="
          flex items-center gap-2.5 px-5 py-2.5 rounded-lg
          bg-action-scrap-bg hover:bg-action-scrap-hover
          border border-action-scrap-border
          text-action-scrap-text hover:text-action-scrap-text-hover
          transition-colors
        "
      >
        <Trash2 size={20} />
        <span className="text-base font-medium">Scrap</span>
      </button>

      {/* Retake */}
      <button
        onClick={handleRetake}
        title="Delete this take and record again"
        className="
          flex items-center gap-2.5 px-5 py-2.5 rounded-lg
          bg-action-retake-bg hover:bg-action-retake-hover
          border border-action-retake-border
          text-action-retake-text hover:text-action-retake-text-hover
          transition-colors
        "
      >
        <RotateCcw size={20} />
        <span className="text-base font-medium">Retake</span>
      </button>

      {/* Keep */}
      <button
        onClick={handleKeep}
        title="Stop recording and keep this take"
        className="
          flex items-center gap-2.5 px-5 py-2.5 rounded-lg
          bg-action-keep-bg hover:bg-action-keep-hover
          border border-action-keep-border
          text-action-keep-text hover:text-action-keep-text-hover
          transition-colors
        "
      >
        <Check size={20} />
        <span className="text-base font-medium">Keep</span>
      </button>
      </div>
    </div>
  );
}
