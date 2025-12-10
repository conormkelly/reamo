/**
 * Region Display Component
 * Shows the current region based on playhead position
 */

import type { ReactElement } from 'react';
import { useMemo } from 'react';
import { MapPin } from 'lucide-react';
import { useReaperStore } from '../../store';

export interface RegionDisplayProps {
  className?: string;
  /** Show icon */
  showIcon?: boolean;
}

export function RegionDisplay({
  className = '',
  showIcon = true,
}: RegionDisplayProps): ReactElement {
  const regions = useReaperStore((state) => state.regions);
  const positionSeconds = useReaperStore((state) => state.positionSeconds);

  // Find the current region based on playhead position
  const currentRegion = useMemo(() => {
    if (regions.length === 0) return null;

    // Find region that contains the current position
    for (const region of regions) {
      if (positionSeconds >= region.start && positionSeconds < region.end) {
        return region;
      }
    }
    return null;
  }, [regions, positionSeconds]);

  if (!currentRegion) {
    return (
      <div
        className={`flex items-center gap-2 px-3 py-2 bg-gray-800 rounded text-gray-500 ${className}`}
      >
        {showIcon && <MapPin size={16} />}
        <span className="text-sm">No region</span>
      </div>
    );
  }

  return (
    <div
      className={`flex items-center gap-2 px-3 py-2 bg-purple-900/50 border border-purple-700 rounded ${className}`}
    >
      {showIcon && <MapPin size={16} className="text-purple-400" />}
      <span className="text-sm font-medium text-purple-200 truncate max-w-[150px]">
        {currentRegion.name}
      </span>
    </div>
  );
}
