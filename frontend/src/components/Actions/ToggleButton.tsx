/**
 * Toggle Button Component
 * A button that shows active/inactive state for toggle actions
 */

import type { ReactElement, ReactNode } from 'react';
import { useReaper } from '../ReaperProvider';
import { action } from '../../core/WebSocketCommands';

export interface ToggleButtonProps {
  /** REAPER action command ID */
  actionId: number | string;
  /** Whether the toggle is currently active */
  isActive: boolean;
  /** Button label */
  children: ReactNode;
  className?: string;
  /** Optional title/tooltip */
  title?: string;
  /** Button size */
  size?: 'sm' | 'md' | 'lg';
  /** Color when active */
  activeColor?: 'green' | 'blue' | 'yellow' | 'red' | 'purple';
  /** Disabled state */
  disabled?: boolean;
}

/**
 * Button that toggles a REAPER action and shows active/inactive state
 *
 * @example
 * ```tsx
 * <ToggleButton
 *   actionId={40364}
 *   isActive={isMetronomeOn}
 *   activeColor="yellow"
 * >
 *   Click
 * </ToggleButton>
 * ```
 */
export function ToggleButton({
  actionId,
  isActive,
  children,
  className = '',
  title,
  size = 'md',
  activeColor = 'green',
  disabled = false,
}: ToggleButtonProps): ReactElement {
  const { sendCommand } = useReaper();

  const handleClick = () => {
    if (!disabled) {
      if (typeof actionId === 'string') {
        sendCommand(action.executeByName(actionId));
      } else {
        sendCommand(action.execute(actionId));
      }
    }
  };

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const activeColorClasses = {
    green: 'bg-success-action text-text-primary hover:bg-success',
    blue: 'bg-primary text-text-primary hover:bg-primary-hover',
    yellow: 'bg-toggle-yellow text-toggle-yellow-text hover:bg-toggle-yellow-hover',
    red: 'bg-error-action text-text-primary hover:bg-error',
    purple: 'bg-accent-region text-text-primary hover:bg-accent-region-hover',
  };

  const inactiveClasses = 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover';

  return (
    <button
      onClick={handleClick}
      disabled={disabled}
      title={title}
      className={`
        ${sizeClasses[size]}
        ${isActive ? activeColorClasses[activeColor] : inactiveClasses}
        rounded font-medium transition-colors
        disabled:opacity-50 disabled:cursor-not-allowed
        ${className}
      `}
    >
      {children}
    </button>
  );
}
