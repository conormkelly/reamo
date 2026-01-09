/**
 * WaveformItem Component
 * Displays a single item as a colored block with waveform visualization
 */

import { type ReactElement } from 'react';
import type { WSItem } from '../../core/WebSocketTypes';
import { reaperColorToRgba } from '../../utils';
import { WaveformCanvas } from './WaveformCanvas';
import { usePeaksFetch } from '../../hooks/usePeaksFetch';
import { DEFAULT_ITEM_COLOR_RGB } from '../../constants/colors';

export interface WaveformItemProps {
  /** The item to display */
  item: WSItem;
  /** Whether the item is selected */
  isSelected: boolean;
  /** Convert time to percentage position */
  timeToPercent: (time: number) => number;
  /** Height of the item in pixels */
  height: number;
  /** Click handler */
  onClick: () => void;
}

export function WaveformItem({
  item,
  isSelected,
  timeToPercent,
  height,
  onClick,
}: WaveformItemProps): ReactElement {
  // Use sparse field for MIDI check
  const isMIDI = item.activeTakeIsMidi ?? false;

  // Fetch peaks for non-MIDI items
  const { peaks, loading } = usePeaksFetch(isMIDI ? null : item);

  // Position and dimensions
  const left = timeToPercent(item.position);
  const width = timeToPercent(item.position + item.length) - left;

  // Background color
  const bgColor = item.color
    ? reaperColorToRgba(item.color, 0.6) ?? DEFAULT_ITEM_COLOR_RGB
    : DEFAULT_ITEM_COLOR_RGB;

  // Take count badge (using sparse field)
  const takeCount = item.takeCount;
  const showTakeBadge = takeCount > 1;

  return (
    <div
      className={`absolute top-2 bottom-2 rounded cursor-pointer transition-all ${
        isSelected
          ? 'ring-2 ring-waveform-selected-ring z-10'
          : 'hover:ring-1 hover:ring-white/30'
      } ${item.locked ? 'opacity-60' : ''}`}
      style={{
        left: `${left}%`,
        width: `${width}%`,
        backgroundColor: bgColor,
        minWidth: '4px',
      }}
      onClick={onClick}
    >
      {/* Waveform or MIDI indicator */}
      <div className="absolute inset-0 overflow-hidden rounded">
        {isMIDI ? (
          // MIDI indicator - colored block with icon
          <div className="flex items-center justify-center h-full text-white/70">
            <svg
              className="w-6 h-6"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={1.5}
                d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3"
              />
            </svg>
          </div>
        ) : loading ? (
          // Loading indicator
          <div className="flex items-center justify-center h-full">
            <div className="w-4 h-4 border-2 border-white/30 border-t-white/70 rounded-full animate-spin" />
          </div>
        ) : peaks ? (
          // Waveform canvas
          <WaveformCanvas peaks={peaks} height={height - 16} />
        ) : null}
      </div>

      {/* Take count badge */}
      {showTakeBadge && (
        <div className="absolute top-1 right-1 bg-black/60 text-white text-[10px] px-1 rounded">
          {item.activeTakeIdx + 1}/{takeCount}
        </div>
      )}

      {/* Lock indicator */}
      {item.locked && (
        <div className="absolute bottom-1 right-1 text-white/70">
          <svg className="w-3 h-3" fill="currentColor" viewBox="0 0 20 20">
            <path
              fillRule="evenodd"
              d="M5 9V7a5 5 0 0110 0v2a2 2 0 012 2v5a2 2 0 01-2 2H5a2 2 0 01-2-2v-5a2 2 0 012-2zm8-2v2H7V7a3 3 0 016 0z"
              clipRule="evenodd"
            />
          </svg>
        </div>
      )}
    </div>
  );
}
