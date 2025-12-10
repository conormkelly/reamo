/**
 * Repeat Button Component
 * Toggle button for repeat/loop mode
 */

import type { ReactElement } from 'react';
import { Repeat } from 'lucide-react';
import { useReaperStore } from '../../store';
import { ToggleButton } from './ToggleButton';
import { ActionCommands } from '../../core/types';

export interface RepeatButtonProps {
  className?: string;
  /** Button size */
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Toggle button for repeat/loop mode
 *
 * Shows active state when loop is enabled in REAPER.
 *
 * @example
 * ```tsx
 * <RepeatButton />
 * <RepeatButton size="lg" />
 * ```
 */
export function RepeatButton({
  className = '',
  size = 'md',
}: RepeatButtonProps): ReactElement {
  const isRepeat = useReaperStore((state) => state.isRepeat);

  return (
    <ToggleButton
      actionId={ActionCommands.TOGGLE_REPEAT}
      isActive={isRepeat}
      title="Toggle Repeat/Loop"
      activeColor="green"
      className={className}
      size={size}
    >
      <Repeat size={16} className="inline-block mr-1" />
      Loop
    </ToggleButton>
  );
}
