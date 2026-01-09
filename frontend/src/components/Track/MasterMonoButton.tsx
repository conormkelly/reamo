/**
 * Master Mono/Stereo Toggle Button
 * Toggles master track between mono (L+R summed) and stereo output
 * Only shown on master track (trackIndex === 0)
 */

import { useCallback, type ReactElement } from 'react';
import { CircleSmall, Unlink2 } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { master } from '../../core/WebSocketCommands';

export interface MasterMonoButtonProps {
  className?: string;
  /** Whether parent track is selected (affects background) */
  isSelected?: boolean;
}

export function MasterMonoButton({
  className = '',
  isSelected = false,
}: MasterMonoButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const masterStereo = useReaperStore((s) => s.masterStereo);
  const isMono = !masterStereo;

  const handleClick = useCallback(() => {
    sendCommand(master.toggleMono());
  }, [sendCommand]);

  // Buttons always darker than track background for contrast
  const inactiveBg = isSelected
    ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
    : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';

  // Active state when mono is enabled
  const activeClass = isMono ? 'bg-warning-bright text-text-primary' : inactiveBg;

  return (
    <button
      onClick={handleClick}
      title={isMono ? 'Mono (L+R summed) - click for Stereo' : 'Stereo - click for Mono'}
      className={`px-2 py-1 rounded text-sm font-medium transition-colors ${activeClass} ${className}`}
    >
      {isMono ? (
        <CircleSmall size={14} className="inline-block" />
      ) : (
        <Unlink2 size={14} className="inline-block" />
      )}
    </button>
  );
}
