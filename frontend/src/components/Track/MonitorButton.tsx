/**
 * Monitor Button Component
 * Cycle through record monitor states: Off → On → Auto
 */

import type { ReactElement } from 'react';
import { Headphones } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';

export interface MonitorButtonProps {
  trackIndex: number;
  className?: string;
  /** Whether parent track is selected (affects background) */
  isSelected?: boolean;
}

export function MonitorButton({
  trackIndex,
  className = '',
  isSelected = false,
}: MonitorButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { recordMonitorState, cycleRecordMonitor } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  const handleClick = () => {
    if (mixerLocked) return;
    sendCommand(cycleRecordMonitor());
  };

  // Buttons always darker than track background for contrast
  const offStyle = isSelected
    ? 'bg-gray-800 text-gray-300 hover:bg-gray-700'
    : 'bg-gray-900 text-gray-300 hover:bg-gray-800';

  const stateStyles = {
    off: offStyle,
    on: 'bg-gray-200 text-gray-900',
    auto: 'bg-red-900 text-red-200',
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
      className={`px-2 py-1 rounded text-sm font-medium transition-colors ${
        mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
      } ${stateStyles[recordMonitorState]} ${className}`}
    >
      <Headphones size={14} className="inline-block" />
    </button>
  );
}
