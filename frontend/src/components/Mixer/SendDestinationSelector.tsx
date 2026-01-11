/**
 * SendDestinationSelector Component
 * Dropdown to select which send destination (aux/cue bus) to control in Sends mode.
 */

import type { ReactElement } from 'react';
import { useSends, type SendDestination } from '../../hooks/useSends';

export interface SendDestinationSelectorProps {
  /** Currently selected destination track index */
  selectedDestIdx: number | null;
  /** Callback when destination changes */
  onDestinationChange: (destIdx: number) => void;
  className?: string;
}

export function SendDestinationSelector({
  selectedDestIdx,
  onDestinationChange,
  className = '',
}: SendDestinationSelectorProps): ReactElement {
  const { destinations } = useSends();

  if (destinations.length === 0) {
    return (
      <div className={`text-text-muted text-sm ${className}`}>
        No sends in project
      </div>
    );
  }

  return (
    <select
      value={selectedDestIdx ?? ''}
      onChange={(e) => onDestinationChange(Number(e.target.value))}
      className={`bg-bg-elevated border border-border-subtle rounded px-2 py-1 text-sm text-amber-400 focus:outline-none focus:ring-1 focus:ring-amber-500/50 ${className}`}
    >
      {destinations.map((dest: SendDestination) => (
        <option key={dest.trackIdx} value={dest.trackIdx}>
          → {dest.name}
        </option>
      ))}
    </select>
  );
}
