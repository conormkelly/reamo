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
    green: 'bg-green-600 text-white hover:bg-green-500',
    blue: 'bg-blue-600 text-white hover:bg-blue-500',
    yellow: 'bg-yellow-500 text-black hover:bg-yellow-400',
    red: 'bg-red-600 text-white hover:bg-red-500',
    purple: 'bg-purple-600 text-white hover:bg-purple-500',
  };

  const inactiveClasses = 'bg-gray-700 text-gray-300 hover:bg-gray-600';

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
