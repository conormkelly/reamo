/**
 * RecordingActionsBar Component
 * Quick actions visible during recording - Scrap, Retake, Keep
 */

import { type ReactElement } from 'react';
import { Trash2, RotateCcw, Check } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import * as commands from '../../core/CommandBuilder';

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
  const { send } = useReaper();
  const { isRecording } = useTransport();

  // Only show when recording
  if (!isRecording) {
    return null;
  }

  const handleScrap = () => {
    // Stop and delete all recorded media (action 40668)
    // REAPER will return playhead to where recording started
    send(commands.abortRecording());
  };

  const handleRetake = () => {
    // Stop and delete all recorded media, then restart recording
    send(commands.abortRecording());

    // Small delay to ensure stop completes, then restart recording
    setTimeout(() => {
      send(commands.record());
    }, 50);
  };

  const handleKeep = () => {
    // Stop recording normally (keeps the take)
    send(commands.stop());
  };

  return (
    <div className={`flex items-center justify-center gap-4 mt-3 ${className}`}>
      {/* Scrap - destructive, red */}
      <button
        onClick={handleScrap}
        title="Stop recording and delete this take"
        className="
          flex items-center gap-2.5 px-5 py-2.5 rounded-lg
          bg-red-900/40 hover:bg-red-800/60
          border border-red-500/50
          text-red-200 hover:text-red-100
          transition-colors
        "
      >
        <Trash2 size={20} />
        <span className="text-base font-medium">Scrap</span>
      </button>

      {/* Retake - amber/orange */}
      <button
        onClick={handleRetake}
        title="Delete this take and record again"
        className="
          flex items-center gap-2.5 px-5 py-2.5 rounded-lg
          bg-amber-900/40 hover:bg-amber-800/60
          border border-amber-500/50
          text-amber-200 hover:text-amber-100
          transition-colors
        "
      >
        <RotateCcw size={20} />
        <span className="text-base font-medium">Retake</span>
      </button>

      {/* Keep - green/success */}
      <button
        onClick={handleKeep}
        title="Stop recording and keep this take"
        className="
          flex items-center gap-2.5 px-5 py-2.5 rounded-lg
          bg-green-900/40 hover:bg-green-800/60
          border border-green-500/50
          text-green-200 hover:text-green-100
          transition-colors
        "
      >
        <Check size={20} />
        <span className="text-base font-medium">Keep</span>
      </button>
    </div>
  );
}
