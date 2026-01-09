/**
 * Action Button Component
 * Base button that triggers any REAPER action by command ID
 */

import { type ReactElement, type ReactNode } from 'react';
import { useReaper } from '../ReaperProvider';
import { action } from '../../core/WebSocketCommands';

export interface ActionButtonProps {
  /** REAPER action command ID (number or registered string ID like "_RS...") */
  actionId: number | string;
  /** Button label */
  children: ReactNode;
  className?: string;
  /** Optional title/tooltip */
  title?: string;
  /** Button variant */
  variant?: 'default' | 'primary' | 'danger' | 'ghost';
  /** Button size */
  size?: 'sm' | 'md' | 'lg';
  /** Disabled state */
  disabled?: boolean;
}

/**
 * Button that triggers any REAPER action
 *
 * Common action IDs:
 * - 1007: Play
 * - 1008: Pause
 * - 1013: Record
 * - 40667: Stop
 * - 40364: Toggle Metronome
 * - 1068: Toggle Repeat
 * - 40172: Previous Marker
 * - 40173: Next Marker
 * - 40029: Undo
 * - 40030: Redo
 * - 40026: Save Project
 *
 * Find more IDs in REAPER's Action List (right-click → Copy command ID)
 */
export function ActionButton({
  actionId,
  children,
  className = '',
  title,
  variant = 'default',
  size = 'md',
  disabled = false,
}: ActionButtonProps): ReactElement {
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

  const variantClasses = {
    default: 'bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled',
    primary: 'bg-primary text-text-primary hover:bg-primary-hover active:bg-primary-active',
    danger: 'bg-error-action text-text-primary hover:bg-error active:bg-error-action',
    ghost: 'bg-transparent text-text-tertiary hover:bg-bg-surface active:bg-bg-elevated',
  };

  return (
    <button
      onClick={handleClick}
      disabled={disabled}
      title={title}
      className={`
        ${sizeClasses[size]}
        ${variantClasses[variant]}
        rounded font-medium transition-colors
        disabled:opacity-50 disabled:cursor-not-allowed
        ${className}
      `}
    >
      {children}
    </button>
  );
}
