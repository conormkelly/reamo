/**
 * TimelineWaveformOverlay Component
 * Renders waveforms for items on the selected track in Navigate mode
 *
 * Positioned to overlay the colored item blobs from ItemsDensityOverlay.
 * Uses WebSocket subscription for peaks - data is pushed when items change.
 */

import { useMemo, useRef, useEffect, type ReactElement } from 'react';
import type { WSItem, StereoPeak, MonoPeak } from '../../core/WebSocketTypes';
import { useSingleTrackPeaks } from '../../hooks/usePeaksSubscription';
import { getContrastColor } from '../../utils';

export interface TimelineWaveformOverlayProps {
  /** Items on the colored track (pre-filtered) */
  items: WSItem[];
  /** Track GUID to subscribe to for peaks */
  trackGuid: string | null;
  /** Timeline start time in seconds */
  timelineStart: number;
  /** Timeline end time in seconds */
  timelineEnd: number;
  /** Height of the container in pixels */
  height: number;
  /** Whether waveform fetching is enabled */
  enabled: boolean;
}

/** Check if peaks are stereo */
function isStereo(peaks: StereoPeak[] | MonoPeak[]): peaks is StereoPeak[] {
  return peaks.length > 0 && typeof peaks[0] === 'object' && 'l' in peaks[0];
}

/** Get waveform colors based on item background color */
function getWaveformColors(itemColor: number | undefined): { fill: string; centerline: string } {
  const contrast = getContrastColor(itemColor ?? 0);
  if (contrast === 'black') {
    return {
      fill: 'rgba(0, 0, 0, 0.6)',
      centerline: 'rgba(0, 0, 0, 0.2)',
    };
  }
  return {
    fill: 'rgba(255, 255, 255, 0.7)',
    centerline: 'rgba(255, 255, 255, 0.2)',
  };
}

/**
 * Draw waveform on canvas - simplified version optimized for small timeline blobs
 */
function drawWaveform(
  ctx: CanvasRenderingContext2D,
  peaks: StereoPeak[] | MonoPeak[],
  width: number,
  height: number,
  fillColor: string,
  centerlineColor: string
): void {
  ctx.clearRect(0, 0, width, height);
  if (peaks.length === 0) return;

  const stereo = isStereo(peaks);
  const peakCount = peaks.length;
  ctx.fillStyle = fillColor;

  if (stereo) {
    // Stereo: draw L channel on top half, R channel on bottom half
    const halfHeight = height / 2;

    // Left channel
    ctx.beginPath();
    for (let i = 0; i < peakCount; i++) {
      const x = (i / peakCount) * width;
      const peak = (peaks as StereoPeak[])[i].l;
      const minY = halfHeight * (1 - Math.abs(peak[0]));
      const maxY = halfHeight * (1 - Math.abs(peak[1]));
      const barHeight = Math.max(1, minY - maxY);
      ctx.rect(x, maxY, Math.max(1, width / peakCount), barHeight);
    }
    ctx.fill();

    // Right channel
    ctx.beginPath();
    for (let i = 0; i < peakCount; i++) {
      const x = (i / peakCount) * width;
      const peak = (peaks as StereoPeak[])[i].r;
      const minY = halfHeight + halfHeight * Math.abs(peak[0]);
      const maxY = halfHeight + halfHeight * Math.abs(peak[1]);
      const barHeight = Math.max(1, maxY - minY);
      ctx.rect(x, minY, Math.max(1, width / peakCount), barHeight);
    }
    ctx.fill();

    // Center line
    ctx.strokeStyle = centerlineColor;
    ctx.beginPath();
    ctx.moveTo(0, halfHeight);
    ctx.lineTo(width, halfHeight);
    ctx.stroke();
  } else {
    // Mono: centered waveform
    const centerY = height / 2;

    ctx.beginPath();
    for (let i = 0; i < peakCount; i++) {
      const x = (i / peakCount) * width;
      const peak = (peaks as MonoPeak[])[i];
      const minVal = Math.abs(peak[0]);
      const maxVal = Math.abs(peak[1]);
      const topY = centerY - centerY * maxVal;
      const bottomY = centerY + centerY * minVal;
      const barHeight = Math.max(1, bottomY - topY);
      ctx.rect(x, topY, Math.max(1, width / peakCount), barHeight);
    }
    ctx.fill();

    // Center line
    ctx.strokeStyle = centerlineColor;
    ctx.beginPath();
    ctx.moveTo(0, centerY);
    ctx.lineTo(width, centerY);
    ctx.stroke();
  }
}

/**
 * Single waveform canvas for an item
 */
function WaveformBlob({
  peaks,
  leftPercent,
  widthPercent,
  topOffset,
  blobHeight,
  itemColor,
}: {
  peaks: StereoPeak[] | MonoPeak[];
  leftPercent: number;
  widthPercent: number;
  topOffset: number;
  blobHeight: number;
  itemColor: number | undefined;
}): ReactElement {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const colors = useMemo(() => getWaveformColors(itemColor), [itemColor]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // Get actual pixel dimensions
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);

    // Draw waveform with contrast colors
    drawWaveform(ctx, peaks, rect.width, rect.height, colors.fill, colors.centerline);
  }, [peaks, blobHeight, colors]);

  return (
    <canvas
      ref={canvasRef}
      className="absolute pointer-events-none"
      style={{
        left: `${leftPercent}%`,
        width: `${widthPercent}%`,
        top: `${topOffset}px`,
        height: `${blobHeight}px`,
      }}
    />
  );
}

export function TimelineWaveformOverlay({
  items,
  trackGuid,
  timelineStart,
  timelineEnd,
  height,
  enabled,
}: TimelineWaveformOverlayProps): ReactElement | null {
  // Subscribe to peaks for the track (data pushed by backend)
  // Use single-track convenience hook for backward compatibility
  const peaksData = useSingleTrackPeaks(enabled ? trackGuid : null);

  // Calculate visible items with full item positions (not clamped)
  // Parent overflow:hidden clips to visible area, so we render full waveform
  // and let CSS handle clipping - this is smoother than re-slicing peaks on pan
  const visibleItems = useMemo(() => {
    const duration = timelineEnd - timelineStart;
    if (duration <= 0) return [];

    return items
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
  }, [items, timelineStart, timelineEnd]);

  // Don't render if no items or not enabled or no peaks data
  if (!enabled || visibleItems.length === 0 || !peaksData) {
    return null;
  }

  // Match blob dimensions from ItemsDensityOverlay
  const blobHeight = height * 0.25;
  const topOffset = (height - blobHeight) / 2;

  return (
    <div
      data-testid="timeline-waveform-overlay"
      className="absolute inset-0 z-[1] pointer-events-none overflow-hidden"
    >
      {visibleItems.map((v) => {
        // Look up peaks by item GUID
        const peaksEntry = peaksData.get(v.item.guid);
        if (!peaksEntry) return null;

        return (
          <WaveformBlob
            key={v.item.guid}
            peaks={peaksEntry.peaks}
            leftPercent={v.leftPercent}
            widthPercent={v.widthPercent}
            topOffset={topOffset}
            blobHeight={blobHeight}
            itemColor={v.item.color}
          />
        );
      })}
    </div>
  );
}
