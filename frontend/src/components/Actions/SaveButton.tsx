/**
 * Save Button
 * Project Save button with dirty state awareness
 */

import { useCallback, type ReactElement } from 'react';
import { Save } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { action } from '../../core/WebSocketCommands';

export interface SaveButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Project Save button
 * - Disabled (grey) when project has no unsaved changes
 * - Green with asterisk when project is dirty (mirrors REAPER's title bar behavior)
 */
export function SaveButton({
  className = '',
  size = 'md',
}: SaveButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const isProjectDirty = useReaperStore((state) => state.isProjectDirty);

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const handleClick = useCallback(() => {
    if (isProjectDirty) {
      sendCommand(action.execute(40026)); // Save Project
    }
  }, [sendCommand, isProjectDirty]);

  // Green when dirty, grey when clean
  const buttonClass = isProjectDirty
    ? 'bg-success-action text-text-on-success hover:bg-success active:bg-success-action'
    : 'bg-bg-elevated text-text-secondary cursor-not-allowed';

  return (
    <button
      onClick={handleClick}
      disabled={!isProjectDirty}
      title={isProjectDirty ? 'Save Project (unsaved changes)' : 'No unsaved changes'}
      className={`
        ${sizeClasses[size]}
        ${buttonClass}
        rounded font-medium transition-colors
        disabled:opacity-50
        ${className}
      `}
    >
      <Save size={16} className="inline-block align-middle mr-1" />
      <span className="align-middle">Save{isProjectDirty ? '*' : ''}</span>
    </button>
  );
}
