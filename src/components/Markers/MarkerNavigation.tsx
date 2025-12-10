/**
 * Marker Navigation Component
 * Previous/Next marker buttons for quick navigation
 */

import type { ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import * as commands from '../../core/CommandBuilder';

export interface MarkerNavigationProps {
  className?: string;
  /** Show labels on buttons */
  showLabels?: boolean;
  /** Button size variant */
  size?: 'sm' | 'md' | 'lg';
}

export function MarkerNavigation({
  className = '',
  showLabels = true,
  size = 'md',
}: MarkerNavigationProps): ReactElement {
  const { send } = useReaper();

  const handlePrev = () => {
    send(commands.prevMarker());
  };

  const handleNext = () => {
    send(commands.nextMarker());
  };

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const buttonClass = `${sizeClasses[size]} rounded font-medium transition-colors bg-gray-700 text-white hover:bg-gray-600 active:bg-gray-500`;

  return (
    <div className={`flex items-center gap-2 ${className}`}>
      <button onClick={handlePrev} className={buttonClass} title="Previous Marker">
        ⏮{showLabels && <span className="ml-1">Prev</span>}
      </button>
      <button onClick={handleNext} className={buttonClass} title="Next Marker">
        {showLabels && <span className="mr-1">Next</span>}⏭
      </button>
    </div>
  );
}
