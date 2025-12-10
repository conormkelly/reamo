/**
 * Tap Tempo Button Component
 * Displays project BPM (calculated from BEATPOS) and allows tapping to set tempo
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import * as commands from '../../core/CommandBuilder';

export interface TapTempoButtonProps {
  className?: string;
  /** Button size */
  size?: 'sm' | 'md' | 'lg';
  /** Show "BPM" label after number */
  showLabel?: boolean;
}

/**
 * Button that displays project BPM and triggers tap tempo
 *
 * Shows the current project tempo (calculated from BEATPOS).
 * Tap repeatedly to set a new tempo - sends tap tempo action to REAPER.
 *
 * @example
 * ```tsx
 * <TapTempoButton />
 * <TapTempoButton showLabel={false} size="lg" />
 * ```
 */
export function TapTempoButton({
  className = '',
  size = 'md',
  showLabel = true,
}: TapTempoButtonProps): ReactElement {
  const { send } = useReaper();
  const bpm = useReaperStore((state) => state.bpm);

  const handleTap = () => {
    send(commands.tapTempo());
  };

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm min-w-16',
    md: 'px-3 py-2 min-w-20',
    lg: 'px-4 py-3 text-lg min-w-24',
  };

  return (
    <button
      onClick={handleTap}
      title="Tap Tempo - tap repeatedly to set BPM"
      className={`
        ${sizeClasses[size]}
        bg-gray-700 text-white hover:bg-gray-600 active:bg-gray-500
        rounded font-medium font-mono transition-colors
        ${className}
      `}
    >
      {bpm !== null ? Math.round(bpm) : '-'}{showLabel ? ' BPM' : ''}
    </button>
  );
}
