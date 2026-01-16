/**
 * ChannelSelector Component
 * Dropdown to select MIDI channel (1-16)
 * Displays 1-16 but stores as 0-15 internally
 */

import type { ReactElement } from 'react';

export interface ChannelSelectorProps {
  /** Currently selected channel (0-15 internal) */
  channel: number;
  /** Callback when channel changes (0-15 internal) */
  onChannelChange: (channel: number) => void;
  className?: string;
}

export function ChannelSelector({
  channel,
  onChannelChange,
  className = '',
}: ChannelSelectorProps): ReactElement {
  // Generate channel options 1-16
  const channelOptions = Array.from({ length: 16 }, (_, i) => i);

  return (
    <div className={`flex items-center gap-1.5 ${className}`}>
      <label htmlFor="midi-channel" className="text-text-secondary text-sm">
        Ch
      </label>
      <select
        id="midi-channel"
        value={channel}
        onChange={(e) => onChannelChange(Number(e.target.value))}
        className="
          bg-bg-surface text-text-primary text-sm
          border border-border-subtle rounded
          px-1.5 py-1.5 w-14
          focus:outline-none focus:ring-2 focus:ring-focus-ring
        "
        aria-label="MIDI Channel"
      >
        {channelOptions.map((ch) => (
          <option key={ch} value={ch}>
            {ch + 1}
          </option>
        ))}
      </select>
    </div>
  );
}
