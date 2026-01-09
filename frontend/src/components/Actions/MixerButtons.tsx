/**
 * Mixer Buttons
 * Track selection and mixer-related action buttons
 */

import { useCallback, type ReactElement } from 'react';
import { X } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { timeSelection } from '../../core/WebSocketCommands';

export interface ClearSelectionButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to clear time selection and loop points
 * Action ID 40020: Remove (unselect) time selection and loop points
 * Also clears the local UI state for the selection
 */
export function ClearSelectionButton({
  className = '',
  size = 'md',
}: ClearSelectionButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const setStoredTimeSelection = useReaperStore((state) => state.setTimeSelection);

  const handleClick = useCallback(() => {
    sendCommand(timeSelection.clear());
    setStoredTimeSelection(null);
  }, [sendCommand, setStoredTimeSelection]);

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  return (
    <button
      onClick={handleClick}
      title="Clear Selection"
      className={`
        ${sizeClasses[size]}
        bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled
        rounded font-medium transition-colors flex items-center
        ${className}
      `}
    >
      <X size={16} className="mr-1" />
      <span>Clear</span>
    </button>
  );
}
