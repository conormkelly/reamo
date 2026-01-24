/**
 * MixerStripCompact - Minimal strip for landscape mode
 *
 * Shows only fader + meter + track name + selection footer.
 * All other controls (pan, M/S, arm/monitor) are accessed via
 * TrackDetailSheet when tapping the strip.
 *
 * This maximizes fader height in landscape where vertical space is limited.
 */

import type { ReactElement } from 'react';
import { useTrack } from '../../hooks/useTrack';
import { Fader, LevelMeter } from '../Track';

export interface MixerStripCompactProps {
  trackIndex: number;
  /** Fader height in pixels */
  faderHeight: number;
  /** Whether this track is selected for info display */
  isInfoSelected?: boolean;
  /** Callback when track is selected for info display */
  onSelectForInfo?: (trackIndex: number) => void;
  /** Callback when strip is tapped to open detail sheet */
  onOpenDetail?: (trackIndex: number) => void;
  className?: string;
}

/**
 * Compact channel strip for landscape mixer view.
 *
 * Layout (top to bottom):
 * - Color bar with track number (8px)
 * - Track name (truncated, ~20px)
 * - Meter + Fader (faderHeight)
 * - Selection footer (16px)
 */
export function MixerStripCompact({
  trackIndex,
  faderHeight,
  isInfoSelected = false,
  onSelectForInfo,
  onOpenDetail,
  className = '',
}: MixerStripCompactProps): ReactElement | null {
  const { exists, name, isSelected, color } = useTrack(trackIndex);

  if (!exists) {
    return null;
  }

  const isMaster = trackIndex === 0;
  const backgroundColor = isSelected ? 'bg-bg-elevated' : 'bg-bg-surface';
  const topBarColor = color || 'var(--color-text-muted)';

  // Handle tap on the main strip area to open detail sheet
  const handleStripTap = () => {
    onOpenDetail?.(trackIndex);
  };

  return (
    <div
      className={`flex flex-col items-center rounded-lg border border-border-subtle ${backgroundColor} ${className}`}
      style={{ width: 72 }}
      data-testid="mixer-strip-compact"
      data-track-index={trackIndex}
    >
      {/* Color bar with track number */}
      <div
        className="w-full h-2 rounded-t-lg flex items-center justify-center"
        style={{ backgroundColor: topBarColor }}
      >
        {!isMaster && (
          <span className="text-[8px] font-medium text-white/80">
            {trackIndex}
          </span>
        )}
      </div>

      {/* Track name - tappable to open detail sheet */}
      <button
        onClick={handleStripTap}
        className="w-full text-center text-[10px] font-medium truncate px-1 py-1 hover:bg-bg-elevated/50 transition-colors"
        title={`${name || (isMaster ? 'MASTER' : `Trk ${trackIndex}`)} - tap for controls`}
        style={color ? { color } : undefined}
      >
        {isMaster ? 'MASTER' : name || `Trk ${trackIndex}`}
      </button>

      {/* Main content: Meter + Fader - tappable to open detail sheet */}
      <button
        onClick={handleStripTap}
        className="flex gap-1 px-1 pb-1 cursor-pointer"
      >
        <LevelMeter
          trackIndex={trackIndex}
          height={faderHeight}
          showPeak={true}
        />
        <Fader
          trackIndex={trackIndex}
          height={faderHeight}
          isSelected={isSelected}
          showDbLabel={false}
        />
      </button>

      {/* Selection footer - solid bar when selected */}
      {onSelectForInfo && (
        <button
          onClick={() => onSelectForInfo(trackIndex)}
          className={`w-full h-4 rounded-b-lg transition-colors ${
            isInfoSelected
              ? 'bg-primary'
              : 'bg-bg-deep hover:bg-bg-elevated border-t border-border-subtle'
          }`}
          title="Select for info"
          aria-pressed={isInfoSelected}
        />
      )}
    </div>
  );
}
