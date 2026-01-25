/**
 * Monitor Button Component
 * Cycle through record monitor states: Off → On → Auto
 *
 * Accessibility: Uses aria-label + live region instead of aria-pressed
 * because aria-pressed is only appropriate for binary toggles.
 */

import { useState, type ReactElement } from 'react';
import { Headphones } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useReaperStore } from '../../store';
import {
  getInactiveClasses,
  getLockedClasses,
  trackControlBaseClasses,
} from './trackControlStyles';

export interface MonitorButtonProps {
  trackIndex: number;
  className?: string;
  /** Whether parent track is selected (affects background) */
  isSelected?: boolean;
}

const stateLabels = {
  off: 'Monitor Off',
  on: 'Monitor On',
  auto: 'Monitor Auto',
} as const;

export function MonitorButton({
  trackIndex,
  className = '',
  isSelected = false,
}: MonitorButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { recordMonitorState, cycleRecordMonitor } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);

  // Live region announcement for screen readers
  const [announcement, setAnnouncement] = useState('');

  const handleClick = () => {
    if (mixerLocked) return;
    sendCommand(cycleRecordMonitor());
    // Announce the next state (what it's changing to)
    const nextState =
      recordMonitorState === 'off'
        ? 'on'
        : recordMonitorState === 'on'
          ? 'auto'
          : 'off';
    setAnnouncement(`Monitor mode: ${stateLabels[nextState]}`);
  };

  const offStyle = getInactiveClasses(isSelected);
  const lockedClasses = getLockedClasses(mixerLocked);

  const stateStyles = {
    off: offStyle,
    on: 'bg-text-tertiary text-bg-deep',
    auto: 'bg-monitor-auto-bg text-monitor-auto-text',
  };

  return (
    <>
      <button
        onClick={handleClick}
        aria-label={stateLabels[recordMonitorState]}
        title={stateLabels[recordMonitorState]}
        className={`px-2 py-1 ${trackControlBaseClasses} ${lockedClasses} ${stateStyles[recordMonitorState]} ${className}`}
      >
        <Headphones size={14} className="inline-block" />
      </button>
      {/* Live region for screen reader announcements */}
      <span role="status" aria-live="polite" className="sr-only">
        {announcement}
      </span>
    </>
  );
}
