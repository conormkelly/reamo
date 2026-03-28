/**
 * MultiTrackLanes Component
 *
 * Renders multiple track lanes showing items across several tracks simultaneously.
 * Uses per-track canvas architecture for 60fps performance on iPad Safari.
 *
 * Architecture (per TIMELINE_CANVAS_ARCHITECTURE.md):
 * - ONE canvas per track lane (not per-item)
 * - Items rendered as rectangles with waveform overlays via tile blitting
 * - ImageBitmap caching for GPU-accelerated rendering
 *
 * Features:
 * - Full-width lanes (no labels - horizontal space is precious on mobile)
 * - Items colored by their item/track color
 * - Selected items highlighted with blue border
 * - Focused track highlighted with subtle background
 * - Waveform overlays via cached ImageBitmap blitting
 *
 * Note: Items are pointer-events-none. Click handling is done at the Timeline
 * level via hit-testing (same pattern as single-track mode).
 */

import { useRef, useEffect, useState, type ReactElement } from 'react';
import type { WSItem, SkeletonTrack, StereoPeak, MonoPeak } from '../../core/WebSocketTypes';
import { WaveformLayer } from './WaveformLayer';

export interface MultiTrackLanesProps {
  /** Track skeleton entries to display as lanes (ordered) */
  tracks: SkeletonTrack[];
  /** Track indices corresponding to tracks (1-based, from bank navigation) */
  trackIndices: number[];
  /** All items in the project */
  items: WSItem[];
  /** Timeline start time in seconds */
  timelineStart: number;
  /** Timeline end time in seconds */
  timelineEnd: number;
  /** Total height available for lanes */
  height: number;
  /** Function to assemble peaks for an item within the current viewport (tile-based) */
  assemblePeaksForViewport?: (
    takeGuid: string,
    itemPosition: number,
    itemLength: number
  ) => StereoPeak[] | MonoPeak[] | null;
  /** Function to check if tiles exist for a take */
  hasTilesForTake?: (takeGuid: string) => boolean;
}

export function MultiTrackLanes({
  tracks,
  trackIndices,
  items,
  timelineStart,
  timelineEnd,
  height,
  assemblePeaksForViewport: _assemblePeaksForViewport, // Not used - WaveformCanvas reads tiles directly
  hasTilesForTake: _hasTilesForTake, // Reserved for loading indicators
}: MultiTrackLanesProps): ReactElement | null {
  // Track container width for WaveformCanvas sizing
  const containerRef = useRef<HTMLDivElement>(null);
  const [containerWidth, setContainerWidth] = useState(0);

  // ResizeObserver to track container width changes
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // Initial measurement
    setContainerWidth(container.offsetWidth);

    const resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        setContainerWidth(entry.contentRect.width);
      }
    });
    resizeObserver.observe(container);

    return () => resizeObserver.disconnect();
  }, []);

  if (tracks.length === 0) return null;

  return (
    <div
      ref={containerRef}
      data-testid="multi-track-lanes"
      className="absolute inset-0 pointer-events-none"
      style={{ height }}
    >
      {containerWidth > 0 && (
        <WaveformLayer
          tracks={tracks}
          trackIndices={trackIndices}
          items={items}
          viewportStart={timelineStart}
          viewportEnd={timelineEnd}
          width={containerWidth}
          height={height}

        />
      )}
    </div>
  );
}
