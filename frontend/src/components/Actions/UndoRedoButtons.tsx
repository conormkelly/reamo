/**
 * Undo/Redo Buttons
 * REAPER project-level undo and redo with state awareness
 */

import { useCallback, type ReactElement } from 'react';
import { Undo2, Redo2 } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';

export interface UndoButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
  /** Callback with action description when undo is triggered */
  onUndo?: (action: string) => void;
}

/**
 * REAPER project-level undo button
 * Uses the project state to enable/disable based on undo availability
 */
export function UndoButton({
  className = '',
  size = 'md',
  onUndo,
}: UndoButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const reaperCanUndo = useReaperStore((state) => state.reaperCanUndo);

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const handleClick = useCallback(() => {
    if (!reaperCanUndo) return;
    // Capture action description before sending (we know what will be undone)
    const actionDesc = reaperCanUndo;
    sendCommand({ command: 'undo/do' });
    if (onUndo) {
      onUndo(actionDesc);
    }
  }, [sendCommand, reaperCanUndo, onUndo]);

  return (
    <button
      onClick={handleClick}
      disabled={!reaperCanUndo}
      title={reaperCanUndo ? `Undo: ${reaperCanUndo}` : 'Nothing to undo'}
      className={`
        ${sizeClasses[size]}
        bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled
        rounded font-medium transition-colors
        disabled:opacity-50 disabled:cursor-not-allowed
        ${className}
      `}
    >
      <Undo2 size={16} className="inline-block align-middle mr-1" />
      <span className="align-middle">Undo</span>
    </button>
  );
}

export interface RedoButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
  /** Callback with action description when redo is triggered */
  onRedo?: (action: string) => void;
}

/**
 * REAPER project-level redo button
 * Uses the project state to enable/disable based on redo availability
 */
export function RedoButton({
  className = '',
  size = 'md',
  onRedo,
}: RedoButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const reaperCanRedo = useReaperStore((state) => state.reaperCanRedo);

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const handleClick = useCallback(() => {
    if (!reaperCanRedo) return;
    // Capture action description before sending (we know what will be redone)
    const actionDesc = reaperCanRedo;
    sendCommand({ command: 'redo/do' });
    if (onRedo) {
      onRedo(actionDesc);
    }
  }, [sendCommand, reaperCanRedo, onRedo]);

  return (
    <button
      onClick={handleClick}
      disabled={!reaperCanRedo}
      title={reaperCanRedo ? `Redo: ${reaperCanRedo}` : 'Nothing to redo'}
      className={`
        ${sizeClasses[size]}
        bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled
        rounded font-medium transition-colors
        disabled:opacity-50 disabled:cursor-not-allowed
        ${className}
      `}
    >
      <Redo2 size={16} className="inline-block align-middle mr-1" />
      <span className="align-middle">Redo</span>
    </button>
  );
}
