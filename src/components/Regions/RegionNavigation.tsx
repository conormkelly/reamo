/**
 * Region Navigation Component
 * Navigate between project regions (requires SWS Extension)
 */

import type { ReactElement } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import * as commands from '../../core/CommandBuilder';

export interface RegionNavigationProps {
  className?: string;
  /** Show labels on buttons */
  showLabels?: boolean;
  /** Button size variant */
  size?: 'sm' | 'md' | 'lg';
}

export function RegionNavigation({
  className = '',
  showLabels = true,
  size = 'md',
}: RegionNavigationProps): ReactElement {
  const { send } = useReaper();

  const handlePrevRegion = () => {
    send(commands.action('_SWS_SELPREVREG'));
  };

  const handleNextRegion = () => {
    send(commands.action('_SWS_SELNEXTREG'));
  };

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const buttonClass = `${sizeClasses[size]} rounded font-medium transition-colors bg-purple-700 text-white hover:bg-purple-600 active:bg-purple-500`;

  return (
    <div className={`flex items-center gap-2 ${className}`}>
      <button onClick={handlePrevRegion} className={buttonClass} title="Previous Region (SWS)">
        <ChevronLeft size={16} className="inline-block" />
        {showLabels && <span className="ml-1">Prev</span>}
      </button>
      <button onClick={handleNextRegion} className={buttonClass} title="Next Region (SWS)">
        {showLabels && <span className="mr-1">Next</span>}
        <ChevronRight size={16} className="inline-block" />
      </button>
    </div>
  );
}
