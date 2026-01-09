/**
 * WaveformCanvas Component
 * Draws waveform peaks on a canvas element
 */

import { useRef, useEffect, type ReactElement } from 'react';
import type { PeaksResponsePayload, StereoPeak, MonoPeak } from '../../core/WebSocketTypes';

export interface WaveformCanvasProps {
  /** Peak data from item/getPeaks command */
  peaks: PeaksResponsePayload;
  /** Height of the canvas in pixels */
  height: number;
  /** Optional visible start offset as fraction of item length (0-1) */
  visibleStart?: number;
  /** Optional visible end offset as fraction of item length (0-1) */
  visibleEnd?: number;
  /** Waveform color */
  color?: string;
}

/**
 * Check if peaks array is stereo
 */
function isStereo(peaks: StereoPeak[] | MonoPeak[]): peaks is StereoPeak[] {
  return peaks.length > 0 && typeof peaks[0] === 'object' && 'l' in peaks[0];
}

// CSS variable fallbacks for canvas (canvas API can't use CSS vars directly)
const WAVEFORM_CENTERLINE_COLOR = 'rgba(255, 255, 255, 0.2)'; // matches --color-waveform-centerline
const WAVEFORM_DEFAULT_COLOR = 'rgba(255, 255, 255, 0.7)'; // matches --color-waveform-default

/**
 * Draw waveform on canvas
 */
function drawWaveform(
  ctx: CanvasRenderingContext2D,
  peaks: StereoPeak[] | MonoPeak[],
  width: number,
  height: number,
  color: string,
  centerlineColor: string = WAVEFORM_CENTERLINE_COLOR
): void {
  ctx.clearRect(0, 0, width, height);

  if (peaks.length === 0) return;

  const stereo = isStereo(peaks);
  const peakCount = peaks.length;

  // Set up drawing style
  ctx.fillStyle = color;

  if (stereo) {
    // Stereo: draw L channel on top half, R channel on bottom half
    const halfHeight = height / 2;

    // Left channel (top)
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

    // Right channel (bottom)
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
    // Mono: draw centered waveform
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

export function WaveformCanvas({
  peaks,
  height,
  visibleStart = 0,
  visibleEnd = 1,
  color = WAVEFORM_DEFAULT_COLOR,
}: WaveformCanvasProps): ReactElement {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // Set canvas size to match container
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);

    // Slice peaks to visible range
    const peaksArray = peaks.peaks;
    const startIdx = Math.floor(visibleStart * peaksArray.length);
    const endIdx = Math.ceil(visibleEnd * peaksArray.length);
    const visiblePeaks = peaksArray.slice(startIdx, endIdx);

    // Draw waveform
    drawWaveform(ctx, visiblePeaks, rect.width, rect.height, color);
  }, [peaks, height, visibleStart, visibleEnd, color]);

  return (
    <canvas
      ref={canvasRef}
      className="w-full h-full"
      style={{ height: `${height}px` }}
    />
  );
}
