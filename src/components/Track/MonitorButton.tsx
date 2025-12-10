/**
 * Monitor Button Component
 * Cycle through record monitor states: Off → On → Auto
 */

import type { ReactElement } from 'react';
import { Headphones } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';

export interface MonitorButtonProps {
  trackIndex: number;
  className?: string;
}

export function MonitorButton({
  trackIndex,
  className = '',
}: MonitorButtonProps): ReactElement {
  const { send } = useReaper();
  const { recordMonitorState, cycleRecordMonitor } = useTrack(trackIndex);

  const handleClick = () => {
    send(cycleRecordMonitor());
  };

  const stateStyles = {
    off: 'bg-gray-700 text-gray-300 hover:bg-gray-600',
    on: 'bg-yellow-500 text-black',
    auto: 'bg-blue-500 text-white',
  };

  const stateLabels = {
    off: 'Monitor Off',
    on: 'Monitor On',
    auto: 'Monitor Auto',
  };

  return (
    <button
      onClick={handleClick}
      title={stateLabels[recordMonitorState]}
      className={`px-2 py-1 rounded text-sm font-medium transition-colors ${stateStyles[recordMonitorState]} ${className}`}
    >
      <Headphones size={14} className="inline-block" />
    </button>
  );
}
