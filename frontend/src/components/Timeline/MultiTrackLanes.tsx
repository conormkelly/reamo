/**
 * MultiTrackLanes Component
 * Renders multiple track lanes showing items across several tracks simultaneously.
 *
 * Part of Timeline View Phase 2: Multi-Track Lanes
 * Shows 4-8 tracks as horizontal lanes with items positioned by time.
 *
 * This is a thin wrapper that renders ItemsDensityOverlay for each track lane,
 * reusing the battle-tested item positioning logic from ItemsDensityOverlay.
 *
 * Features:
 * - Full-width lanes (no labels - horizontal space is precious on mobile)
 * - Items colored by their item/track color
 * - Selected items highlighted with blue border
 * - Focused track highlighted with subtle background
 * - Waveform overlays on items (when peaks data available)
 *
 * Note: Items are pointer-events-none. Click handling is done at the Timeline
 * level via hit-testing (same pattern as single-track mode).
 */

import { useMemo, useRef, useEffect, type ReactElement } from 'react';
import type { WSItem, SkeletonTrack, WSItemPeaks, StereoPeak, MonoPeak } from '../../core/WebSocketTypes';
import { reaperColorToRgba, getContrastColor } from '../../utils';

// Default item color when no color set - matches ItemsDensityOverlay
const DEFAULT_ITEM_COLOR = 'rgba(129, 137, 137, 0.6)';

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
  /** Currently focused track GUID (shows highlight) */
  focusedTrackGuid?: string | null;
  /** Peaks data keyed by track index (from usePeaksSubscription) */
  peaksByTrack?: Map<number, Map<string, WSItemPeaks>>;
}

/** Get item color with fallback - same logic as ItemsDensityOverlay */
function getItemColor(item: WSItem, opacity: number = 0.6): string {
  if (!item.color) return DEFAULT_ITEM_COLOR;
  return reaperColorToRgba(item.color, opacity) ?? DEFAULT_ITEM_COLOR;
}

/** Check if peaks are stereo */
function isStereo(peaks: StereoPeak[] | MonoPeak[]): peaks is StereoPeak[] {
  return peaks.length > 0 && typeof peaks[0] === 'object' && 'l' in peaks[0];
}

/** Mini waveform canvas for multi-track lanes (combined mono-style for space efficiency) */
function LaneWaveform({
  peaks,
  color,
}: {
  peaks: StereoPeak[] | MonoPeak[];
  color: string;
}): ReactElement {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || peaks.length === 0) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // Set canvas size to match container
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);

    const width = rect.width;
    const height = rect.height;
    const centerY = height / 2;

    // Clear
    ctx.clearRect(0, 0, width, height);

    // Draw waveform (combined mono-style for cramped lanes per plan Q9)
    ctx.fillStyle = color;

    const sampleWidth = width / peaks.length;

    peaks.forEach((peak, i) => {
      // For stereo, combine L+R into single peak (average)
      // For mono, use as-is
      let minVal: number;
      let maxVal: number;

      if (isStereo(peaks)) {
        const stereoPeak = peak as StereoPeak;
        minVal = (stereoPeak.l[0] + stereoPeak.r[0]) / 2;
        maxVal = (stereoPeak.l[1] + stereoPeak.r[1]) / 2;
      } else {
        const monoPeak = peak as MonoPeak;
        minVal = monoPeak[0];
        maxVal = monoPeak[1];
      }

      // Scale to canvas height
      const x = i * sampleWidth;
      const topY = centerY - maxVal * centerY;
      const bottomY = centerY - minVal * centerY;

      ctx.fillRect(x, topY, Math.max(sampleWidth - 0.5, 1), bottomY - topY);
    });
  }, [peaks, color]);

  return (
    <canvas
      ref={canvasRef}
      className="absolute inset-0 w-full h-full"
      style={{ pointerEvents: 'none' }}
    />
  );
}

/** An individual item with position data for rendering */
interface VisibleItem {
  item: WSItem;
  leftPercent: number;
  widthPercent: number;
}

export function MultiTrackLanes({
  tracks,
  trackIndices,
  items,
  timelineStart,
  timelineEnd,
  height,
  focusedTrackGuid,
  peaksByTrack,
}: MultiTrackLanesProps): ReactElement | null {
  // Group items by trackIdx for efficient lookup
  const itemsByTrack = useMemo(() => {
    const map = new Map<number, WSItem[]>();
    for (const item of items) {
      const existing = map.get(item.trackIdx);
      if (existing) {
        existing.push(item);
      } else {
        map.set(item.trackIdx, [item]);
      }
    }
    return map;
  }, [items]);

  // Calculate lane dimensions
  const laneCount = tracks.length;
  if (laneCount === 0) return null;

  const laneHeight = height / laneCount;
  const duration = timelineEnd - timelineStart;

  // Item sizing within each lane - 60% of lane height, centered
  // (Proportionally similar to single-track's 25% of full height)
  const itemHeightPercent = 60;

  return (
    <div
      data-testid="multi-track-lanes"
      className="absolute inset-0 pointer-events-none"
      style={{ height }}
    >
      {tracks.map((track, laneIdx) => {
        // Use passed track indices directly (slot-based for sequential banks)
        const trackIdx = trackIndices[laneIdx];
        if (trackIdx === undefined) return null; // Skip if index not available
        const trackItems = itemsByTrack.get(trackIdx) ?? [];
        const isFocused = focusedTrackGuid === track.g;

        // Calculate visible items for this track
        // Full item positions (not clamped) - parent overflow:hidden clips to visible area
        // This is smoother than re-slicing peaks on pan (no slinky stretching)
        const visibleItems: VisibleItem[] = duration <= 0 ? [] : trackItems
          .filter((item) => {
            const itemEnd = item.position + item.length;
            return itemEnd > timelineStart && item.position < timelineEnd;
          })
          .map((item) => ({
            item,
            // Full item position (can be negative if item starts before viewport)
            leftPercent: ((item.position - timelineStart) / duration) * 100,
            // Full item width (can extend past 100% if item ends after viewport)
            widthPercent: (item.length / duration) * 100,
          }));

        // Calculate item vertical position within lane (centered)
        const itemTopPercent = (100 - itemHeightPercent) / 2;

        return (
          <div
            key={track.g}
            data-testid={`track-lane-${trackIdx}`}
            className={`
              absolute left-0 right-0 overflow-hidden border-b border-border-subtle/30
              ${isFocused ? 'bg-primary/10' : ''}
            `}
            style={{
              top: laneIdx * laneHeight,
              height: laneHeight,
            }}
          >
            {/* Items - same rendering as ItemsDensityOverlay, with waveform overlay */}
            {visibleItems.map((v) => {
              // Look up peaks for this item
              const trackPeaks = peaksByTrack?.get(trackIdx);
              const itemPeaks = trackPeaks?.get(v.item.guid);
              const bgColor = getItemColor(v.item);
              // Waveform color: contrast against item background
              const contrastBase = v.item.color ? getContrastColor(v.item.color) : 'white';
              const waveformColor = contrastBase === 'white' ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.7)';

              return (
                <div
                  key={`item-${v.item.trackIdx}-${v.item.itemIdx}`}
                  data-testid={`lane-item-${v.item.trackIdx}-${v.item.itemIdx}`}
                  data-selected={v.item.selected}
                  className="absolute pointer-events-none overflow-hidden"
                  style={{
                    left: `${v.leftPercent}%`,
                    width: `${v.widthPercent}%`,
                    top: `${itemTopPercent}%`,
                    height: `${itemHeightPercent}%`,
                    backgroundColor: bgColor,
                    // Selected: blue inset squared border - matches ItemsDensityOverlay
                    boxShadow: v.item.selected ? 'inset 0 0 0 2px var(--color-primary)' : 'none',
                    zIndex: v.item.selected ? 10 : 0,
                  }}
                >
                  {/* Waveform overlay when peaks available */}
                  {itemPeaks && itemPeaks.peaks.length > 0 && (
                    <LaneWaveform
                      peaks={itemPeaks.peaks}
                      color={waveformColor}
                    />
                  )}
                </div>
              );
            })}
          </div>
        );
      })}
    </div>
  );
}
