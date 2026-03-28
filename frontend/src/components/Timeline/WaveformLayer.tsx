/**
 * WaveformLayer - Container for per-track WaveformCanvas components
 *
 * Per architecture doc (Layer 2):
 * - One WaveformCanvas per track lane
 * - Viewport-sized canvases (not item-sized)
 * - Items are rendered as colored rectangles with waveform overlays
 *
 * This replaces the per-item LaneWaveform approach with a more efficient
 * per-track canvas architecture. Each track gets ONE canvas that renders
 * all its items via tile blitting.
 *
 * Performance benefits:
 * - Reduces DOM elements (1 canvas per track vs 1 per item)
 * - Fixed canvas size regardless of item count/duration
 * - GPU-accelerated tile blitting via ImageBitmap
 */

import { useMemo, type ReactElement } from 'react';
import type { WSItem, SkeletonTrack } from '../../core/WebSocketTypes';
import { EMPTY_ITEMS } from '../../store/stableRefs';
import { WaveformCanvas } from './WaveformCanvas';

export interface WaveformLayerProps {
  /** Track skeleton entries to display as lanes (ordered) */
  tracks: SkeletonTrack[];
  /** Track indices corresponding to tracks (1-based, from bank navigation) */
  trackIndices: number[];
  /** All items in the project */
  items: WSItem[];
  /** Viewport start time in seconds */
  viewportStart: number;
  /** Viewport end time in seconds */
  viewportEnd: number;
  /** Container width in pixels */
  width: number;
  /** Total height for all lanes */
  height: number;
}

export function WaveformLayer({
  tracks,
  trackIndices,
  items,
  viewportStart,
  viewportEnd,
  width,
  height,
}: WaveformLayerProps): ReactElement | null {
  // Group items by track index for efficient per-lane rendering
  const itemsByTrackIdx = useMemo(() => {
    const map = new Map<number, WSItem[]>();
    for (const item of items) {
      // eslint-disable-next-line no-restricted-syntax -- mutable array built inside useMemo
      const existing = map.get(item.trackIdx) ?? [];
      existing.push(item);
      map.set(item.trackIdx, existing);
    }
    return map;
  }, [items]);

  if (tracks.length === 0 || width === 0 || height === 0) return null;

  const laneHeight = height / tracks.length;

  return (
    <div
      className="absolute inset-0"
      style={{
        pointerEvents: 'none',
      }}
    >
      {tracks.map((track, laneIdx) => {
        const trackIdx = trackIndices[laneIdx];
        const laneItems = itemsByTrackIdx.get(trackIdx) ?? (EMPTY_ITEMS as WSItem[]);
        return (
          <div
            key={track.g}
            className="absolute left-0 right-0"
            style={{
              top: laneIdx * laneHeight,
              height: laneHeight,
              // Selected track highlight — driven by REAPER's track selection state
              backgroundColor: track.sel ? 'rgba(59, 130, 246, 0.1)' : undefined,
            }}
          >
            <WaveformCanvas
              trackIdx={trackIdx}
              width={width}
              height={laneHeight}
              viewportStart={viewportStart}
              viewportEnd={viewportEnd}
              items={laneItems}
            />
          </div>
        );
      })}
    </div>
  );
}
