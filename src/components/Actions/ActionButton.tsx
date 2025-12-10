/**
 * Action Button Component
 * Triggers any REAPER action by command ID
 */

import type { ReactElement, ReactNode } from 'react';
import { Music, Undo2, Redo2, Save } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import * as commands from '../../core/CommandBuilder';

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
  const { send } = useReaper();

  const handleClick = () => {
    if (!disabled) {
      send(commands.action(actionId));
    }
  };

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const variantClasses = {
    default: 'bg-gray-700 text-white hover:bg-gray-600 active:bg-gray-500',
    primary: 'bg-blue-600 text-white hover:bg-blue-500 active:bg-blue-700',
    danger: 'bg-red-600 text-white hover:bg-red-500 active:bg-red-700',
    ghost: 'bg-transparent text-gray-300 hover:bg-gray-800 active:bg-gray-700',
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

// Pre-configured common action buttons

export interface MetronomeButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

export function MetronomeButton({
  className = '',
  size = 'md',
}: MetronomeButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40364}
      title="Toggle Metronome"
      className={className}
      size={size}
    >
      <Music size={16} className="inline-block mr-1" />
      Click
    </ActionButton>
  );
}

export interface UndoButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

export function UndoButton({
  className = '',
  size = 'md',
}: UndoButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40029}
      title="Undo"
      className={className}
      size={size}
    >
      <Undo2 size={16} className="inline-block mr-1" />
      Undo
    </ActionButton>
  );
}

export interface RedoButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

export function RedoButton({
  className = '',
  size = 'md',
}: RedoButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40030}
      title="Redo"
      className={className}
      size={size}
    >
      <Redo2 size={16} className="inline-block mr-1" />
      Redo
    </ActionButton>
  );
}

export interface SaveButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

export function SaveButton({
  className = '',
  size = 'md',
}: SaveButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40026}
      title="Save Project"
      variant="primary"
      className={className}
      size={size}
    >
      <Save size={16} className="inline-block mr-1" />
      Save
    </ActionButton>
  );
}
