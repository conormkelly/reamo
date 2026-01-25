/**
 * CircularTransportButton Component
 * Unified circular button for transport controls (play, stop, record, etc.)
 * Used by TransportBar (44px) and PersistentTransport (40px).
 */

import type { ReactElement, ReactNode } from 'react';

export interface CircularTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  /** Custom inactive styling (e.g., record button ring) */
  inactiveClass?: string;
  title: string;
  children: ReactNode;
  /** Pulsing animation for recording state */
  pulse?: boolean;
  /** Button size: 'sm' = 40px, 'md' = 44px (Apple HIG minimum) */
  size?: 'sm' | 'md';
}

const activeColorClasses = {
  green: 'bg-success',
  red: 'bg-error',
  gray: 'bg-bg-hover',
} as const;

const sizeClasses = {
  sm: 'w-10 h-10', // 40px - compact (PersistentTransport)
  md: 'w-11 h-11', // 44px - Apple HIG minimum (TransportBar)
} as const;

export function CircularTransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  inactiveClass,
  title,
  children,
  pulse = false,
  size = 'md',
}: CircularTransportButtonProps): ReactElement {
  const defaultInactiveClass = 'bg-bg-elevated hover:bg-bg-hover';

  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      aria-pressed={isActive}
      className={`
        ${sizeClasses[size]} rounded-full flex items-center justify-center
        transition-colors
        ${isActive ? activeColorClasses[activeColor] : (inactiveClass || defaultInactiveClass)}
        ${pulse ? 'animate-pulse' : ''}
      `}
    >
      {children}
    </button>
  );
}
