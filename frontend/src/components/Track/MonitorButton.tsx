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
    ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
    : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';

  const stateStyles = {
    off: offStyle,
    on: 'bg-text-tertiary text-bg-deep',
    auto: 'bg-monitor-auto-bg text-monitor-auto-text',
  };

  const stateLabels = {
    off: 'Monitor Off',
    on: 'Monitor On',
    auto: 'Monitor Auto',
  };

  return (
    <button
      onClick={handleClick}
      aria-pressed={recordMonitorState !== 'off'}
      title={stateLabels[recordMonitorState]}
      className={`px-2 py-1 rounded text-sm font-medium transition-colors ${
        mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
      } ${stateStyles[recordMonitorState]} ${className}`}
    >
      <Headphones size={14} className="inline-block" />
    </button>
  );
}
