/**
 * WaveformCanvas - Per-track canvas with tile-based ImageBitmap blitting
 *
 * Architecture per TIMELINE_CANVAS_ARCHITECTURE.md (Google Maps tile approach):
 * 1. Tiles are pre-rendered to ImageBitmap (via TileBitmapCache)
 * 2. Canvas blits cached bitmaps using ctx.drawImage() - GPU accelerated
 * 3. Position calculation maps tile time range to screen pixels
 *
 * Key optimizations for 60fps iPad:
 * - Single canvas per track lane (not per-item) - reduces DOM overhead
 * - Viewport-sized canvas (fixed size regardless of content)
 * - 1x DPR for waveforms (4x memory savings, acceptable for waveform detail)
 * - GPU compositing via translateZ(0)
 * - ImageBitmap blitting is GPU-accelerated
 * - NEVER-CLEAR rendering: clear only item regions, never entire canvas
 * - Synchronous fallback: adjacent LOD or direct peaks when tile not cached
 *
 * Per research doc: "Pre-render waveforms to ImageBitmap for GPU-accelerated blitting"
 * ctx.drawImage(cachedBitmap, ...) is blazing fast compared to fillRect loops.
 */

import { useRef, useEffect, useState, type ReactElement } from 'react';
import type { WSItem, TileCacheKey, LODLevel, StereoPeak, MonoPeak } from '../../core/WebSocketTypes';
import { LOD_CONFIGS } from '../../core/WebSocketTypes';
import { tileBitmapCache, TILE_RENDER_WIDTH } from '../../core/TileBitmapCache';
import { reaperColorToRgba, getContrastColor } from '../../utils';
import { useReaperStore } from '../../store';
import { EMPTY_STRING_ARRAY } from '../../store/stableRefs';

// Debug flag: set to true to visualize tile cache hits/misses
const DEBUG_TILES = false;

// Default item color when no color set
const DEFAULT_ITEM_COLOR = 'rgba(129, 137, 137, 0.6)';

// LOD levels to try as bitmap fallbacks (relative to current LOD)
// Prefer closer LODs first for better visual quality
const FALLBACK_LOD_OFFSETS = [-1, 1, -2, 2] as const;

export interface WaveformCanvasProps {
  /** Track index (1-based, for display purposes) */
  trackIdx: number;
  /** Canvas width (viewport width in pixels) */
  width: number;
  /** Canvas height (lane height in pixels) */
  height: number;
  /** Viewport start time in seconds */
  viewportStart: number;
  /** Viewport end time in seconds */
  viewportEnd: number;
  /** Items to render in this track lane */
  items: WSItem[];
}

/** Get effective color: active take color > item color > track color */
function getEffectiveColor(item: WSItem, trackColor?: number): number | null {
  return item.activeTakeColor ?? (item.color || null) ?? (trackColor || null);
}

/** Get item color with fallback */
function getItemColor(item: WSItem, trackColor?: number, opacity: number = 0.6): string {
  const color = getEffectiveColor(item, trackColor);
  if (!color) return DEFAULT_ITEM_COLOR;
  return reaperColorToRgba(color, opacity) ?? DEFAULT_ITEM_COLOR;
}

/** Get waveform color that contrasts with item background */
function getWaveformColor(item: WSItem, trackColor?: number): string {
  const color = getEffectiveColor(item, trackColor);
  const contrastBase = color ? getContrastColor(color) : 'white';
  return contrastBase === 'white' ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.7)';
}

/** Parse tile cache key string to TileCacheKey object */
function parseTileCacheKey(keyStr: string): TileCacheKey | null {
  const parts = keyStr.split(':');
  if (parts.length < 4) return null;
  return {
    takeGuid: parts[0],
    epoch: parseInt(parts[1], 10),
    lod: parseInt(parts[2], 10) as LODLevel,
    tileIndex: parseInt(parts[3], 10),
  };
}

/** Check if peaks are stereo */
function isStereo(peaks: StereoPeak[] | MonoPeak[]): peaks is StereoPeak[] {
  return peaks.length > 0 && typeof peaks[0] === 'object' && 'l' in peaks[0];
}

/**
 * Draw peaks directly to canvas (synchronous fallback when no bitmap cached).
 * Slower than ImageBitmap blitting but prevents visual gaps during cache misses.
 * Stereo files render as split lanes (L top, R bottom).
 */
function drawPeaksDirect(
  ctx: CanvasRenderingContext2D,
  peaks: StereoPeak[] | MonoPeak[],
  x: number,
  y: number,
  width: number,
  height: number,
  color: string
): void {
  if (peaks.length === 0) return;

  ctx.fillStyle = color;
  const sampleWidth = width / peaks.length;
  const stereo = isStereo(peaks);

  // For stereo: L in top half, R in bottom half
  // For mono: centered waveform using full height
  const laneHeight = stereo ? height / 2 : height;
  const lCenterY = y + (stereo ? height / 4 : height / 2);
  const rCenterY = y + (3 * height) / 4;

  for (let i = 0; i < peaks.length; i++) {
    const peak = peaks[i];
    const peakX = x + i * sampleWidth;
    const barWidth = Math.max(sampleWidth - 0.5, 1);

    if (stereo) {
      const stereoPeak = peak as StereoPeak;

      // Left channel (top half)
      const lMin = stereoPeak.l[0];
      const lMax = stereoPeak.l[1];
      const lTopY = lCenterY - lMax * (laneHeight / 2);
      const lBottomY = lCenterY - lMin * (laneHeight / 2);
      const lHeight = Math.max(lBottomY - lTopY, 1);
      const lAdjustedTop = lHeight === 1 ? lCenterY - 0.5 : lTopY;
      ctx.fillRect(peakX, lAdjustedTop, barWidth, lHeight);

      // Right channel (bottom half)
      const rMin = stereoPeak.r[0];
      const rMax = stereoPeak.r[1];
      const rTopY = rCenterY - rMax * (laneHeight / 2);
      const rBottomY = rCenterY - rMin * (laneHeight / 2);
      const rHeight = Math.max(rBottomY - rTopY, 1);
      const rAdjustedTop = rHeight === 1 ? rCenterY - 0.5 : rTopY;
      ctx.fillRect(peakX, rAdjustedTop, barWidth, rHeight);
    } else {
      const monoPeak = peak as MonoPeak;
      const minVal = monoPeak[0];
      const maxVal = monoPeak[1];
      const topY = lCenterY - maxVal * (laneHeight / 2);
      const bottomY = lCenterY - minVal * (laneHeight / 2);
      const peakHeight = Math.max(bottomY - topY, 1);
      const adjustedTopY = peakHeight === 1 ? lCenterY - 0.5 : topY;
      ctx.fillRect(peakX, adjustedTopY, barWidth, peakHeight);
    }
  }
}

/** Drawn region tracker for never-clear rendering */
interface DrawnRegion {
  x: number;
  width: number;
}

/**
 * Clear canvas regions not covered by drawn items.
 * Prevents stale waveforms from previous viewport positions.
 */
function clearUncoveredRegions(
  ctx: CanvasRenderingContext2D,
  drawnRegions: DrawnRegion[],
  canvasWidth: number,
  canvasHeight: number
): void {
  if (drawnRegions.length === 0) {
    // No items drawn - clear entire canvas
    ctx.clearRect(0, 0, canvasWidth, canvasHeight);
    return;
  }

  // Sort regions by x position
  const sorted = [...drawnRegions].sort((a, b) => a.x - b.x);

  // Clear gap before first region
  if (sorted[0].x > 0) {
    ctx.clearRect(0, 0, sorted[0].x, canvasHeight);
  }

  // Clear gaps between regions
  for (let i = 0; i < sorted.length - 1; i++) {
    const currentEnd = sorted[i].x + sorted[i].width;
    const nextStart = sorted[i + 1].x;
    if (nextStart > currentEnd) {
      ctx.clearRect(currentEnd, 0, nextStart - currentEnd, canvasHeight);
    }
  }

  // Clear gap after last region
  const lastRegion = sorted[sorted.length - 1];
  const lastEnd = lastRegion.x + lastRegion.width;
  if (lastEnd < canvasWidth) {
    ctx.clearRect(lastEnd, 0, canvasWidth - lastEnd, canvasHeight);
  }
}

export function WaveformCanvas({
  trackIdx,
  width,
  height,
  viewportStart,
  viewportEnd,
  items,
}: WaveformCanvasProps): ReactElement {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [renderTrigger, setRenderTrigger] = useState(0);

  // Get tile data from store
  const currentLod = useReaperStore((s) => s.currentLod);
  const tileCache = useReaperStore((s) => s.tileCache);
  const tilesByTake = useReaperStore((s) => s.tilesByTake);
  // Track color from skeleton (available for ALL tracks, not just subscribed ones)
  const trackColor = useReaperStore((s) => s.trackSkeleton[trackIdx]?.c ?? 0);

  useEffect(() => {
    // Item layout constants (matches MultiTrackLanes)
    // Round to whole pixels for consistent rendering
    const itemTopPercent = 10;
    const itemHeightPercent = 80;
    const itemY = Math.round((itemTopPercent / 100) * height);
    const itemHeight = Math.round((itemHeightPercent / 100) * height);

    // Note: We MUST redraw on every viewport change (including during pan gestures)
    // because items need to be at different pixel positions. ImageBitmap blitting is
    // fast enough for 60fps redraws.
    //
    // NEVER-CLEAR RENDERING: We only clear individual item regions before drawing,
    // not the entire canvas. This prevents visual holes when tiles aren't cached.

    const canvas = canvasRef.current;
    if (!canvas || width === 0 || height === 0) return;

    const ctx = canvas.getContext('2d', { alpha: true });
    if (!ctx) return;

    // Set canvas size only if changed (1x DPR for waveforms - saves 4x memory)
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }

    const viewportDuration = viewportEnd - viewportStart;
    if (viewportDuration <= 0) return;

    // Track drawn regions for cleanup of stale areas
    const drawnRegions: DrawnRegion[] = [];
    // Track pending bitmap renders for async re-render
    const pendingRenders: Promise<void>[] = [];

    // Debug stats
    let draws = 0;
    let fallbacks = 0;

    // Render each item
    for (const item of items) {
      const itemStart = item.position;
      const itemEnd = item.position + item.length;

      // Skip items completely outside viewport (with small buffer)
      if (itemEnd <= viewportStart - 0.1 || itemStart >= viewportEnd + 0.1) continue;

      // Calculate item screen position (clipped to viewport)
      // IMPORTANT: Round to whole pixels to prevent sub-pixel shimmer at edges
      const leftRatio = Math.max(0, (itemStart - viewportStart) / viewportDuration);
      const rightRatio = Math.min(1, (itemEnd - viewportStart) / viewportDuration);
      const itemX = Math.round(leftRatio * width);
      const itemRight = Math.round(rightRatio * width);
      const itemWidth = itemRight - itemX;

      if (itemWidth < 1) continue; // Too small to render

      // PHASE 1: Clear ONLY this item's region, not entire canvas
      ctx.clearRect(itemX, 0, itemWidth, height);

      // Draw item background (always succeeds - provides base color even if tiles missing)
      ctx.fillStyle = getItemColor(item, trackColor);
      ctx.fillRect(itemX, itemY, itemWidth, itemHeight);

      // Draw selection border — only show left/right edges if actually visible
      // in the viewport (items clipped to viewport shouldn't show borders at edges)
      if (item.selected) {
        const leftVisible = itemStart >= viewportStart;
        const rightVisible = itemEnd <= viewportEnd;
        ctx.strokeStyle = '#3b82f6'; // --color-primary
        ctx.lineWidth = 2;
        ctx.beginPath();
        // Top edge (always)
        ctx.moveTo(leftVisible ? itemX + 1 : itemX, itemY + 1);
        ctx.lineTo(rightVisible ? itemRight - 1 : itemRight, itemY + 1);
        // Right edge (only if item ends within viewport)
        if (rightVisible) {
          ctx.lineTo(itemRight - 1, itemY + itemHeight - 1);
        } else {
          ctx.moveTo(rightVisible ? itemRight - 1 : itemRight, itemY + itemHeight - 1);
        }
        // Bottom edge (always)
        ctx.lineTo(leftVisible ? itemX + 1 : itemX, itemY + itemHeight - 1);
        // Left edge (only if item starts within viewport)
        if (leftVisible) {
          ctx.lineTo(itemX + 1, itemY + 1);
        }
        ctx.stroke();
      }

      // Track this region as drawn
      drawnRegions.push({ x: itemX, width: itemWidth });

      // Skip MIDI items and items without take GUID
      if (item.activeTakeIsMidi || !item.activeTakeGuid) continue;

      // Get tiles for this item's take
      const takeKeyStrings = tilesByTake.get(item.activeTakeGuid) ?? EMPTY_STRING_ARRAY;
      const waveformColor = getWaveformColor(item, trackColor);
      const bitmapHeight = Math.round(itemHeight);

      // Render tiles at current LOD, with fallback chain for missing bitmaps
      const lodFilter = `:${currentLod}:`;

      for (const keyStr of takeKeyStrings) {
        // Filter to current LOD only
        if (!keyStr.includes(lodFilter)) continue;

        const tile = tileCache.get(keyStr);
        if (!tile || tile.peaks.length === 0) continue;

        // Calculate tile's absolute time range
        const tileAbsStart = tile.itemPosition + tile.startTime;
        const tileAbsEnd = tile.itemPosition + tile.endTime;

        // Skip tiles outside viewport
        if (tileAbsEnd <= viewportStart || tileAbsStart >= viewportEnd) continue;

        // Calculate tile screen position
        const tileLeftRatio = (tileAbsStart - viewportStart) / viewportDuration;
        const tileRightRatio = (tileAbsEnd - viewportStart) / viewportDuration;
        const tileX = Math.round(tileLeftRatio * width);
        const tileRight = Math.round(tileRightRatio * width);
        const tileScreenWidth = tileRight - tileX;
        if (tileScreenWidth <= 0) continue;

        // Clip tile to item bounds
        const clippedX = Math.max(tileX, itemX);
        const clippedRight = Math.min(tileRight, itemRight);
        const clippedWidth = clippedRight - clippedX;
        if (clippedWidth <= 0) continue;

        // Parse tile cache key for bitmap lookup
        const tileKey = parseTileCacheKey(keyStr);
        if (!tileKey) continue;

        // Calculate source rect for bitmap
        const srcClipLeft = ((clippedX - tileX) / tileScreenWidth) * TILE_RENDER_WIDTH;
        const srcClipWidth = (clippedWidth / tileScreenWidth) * TILE_RENDER_WIDTH;

        // TRY 1: Exact cached bitmap (fast path - GPU-accelerated blit)
        const cachedBitmap = tileBitmapCache.get(tileKey, waveformColor, bitmapHeight);

        if (cachedBitmap) {
          ctx.drawImage(
            cachedBitmap,
            srcClipLeft, 0, srcClipWidth, cachedBitmap.height, // source rect
            clippedX, itemY, clippedWidth, itemHeight // dest rect
          );
          draws++;

          if (DEBUG_TILES) {
            ctx.strokeStyle = 'rgba(0, 255, 0, 0.8)'; // Green = cache hit
            ctx.lineWidth = 1;
            ctx.strokeRect(clippedX, itemY, clippedWidth, itemHeight);
          }
          continue;
        }

        // TRY 2: Adjacent LOD bitmaps with time-corrected tile index.
        // Different LODs have different tile durations, so we calculate
        // which tile at the fallback LOD covers the same time range.
        let drewFallback = false;
        for (const lodOffset of FALLBACK_LOD_OFFSETS) {
          const fallbackLod = (currentLod + lodOffset) as LODLevel;
          if (fallbackLod < 0 || fallbackLod > 6) continue;

          const fallbackConfig = LOD_CONFIGS[fallbackLod as keyof typeof LOD_CONFIGS];
          if (!fallbackConfig) continue;

          // Find the fallback tile that covers the midpoint of our tile
          const tileMidTime = tile.startTime + (tile.endTime - tile.startTime) / 2;
          const fallbackTileIndex = Math.floor(tileMidTime / fallbackConfig.duration);

          const fallbackKey: TileCacheKey = {
            ...tileKey,
            lod: fallbackLod,
            tileIndex: fallbackTileIndex,
          };
          const fallbackBitmap = tileBitmapCache.get(fallbackKey, waveformColor, bitmapHeight);

          if (fallbackBitmap) {
            // Calculate source rect: what portion of the fallback bitmap
            // corresponds to our current tile's time range
            const fbTileStart = fallbackTileIndex * fallbackConfig.duration;
            const fbTileDuration = fallbackConfig.duration;
            const fbSrcLeft = ((tile.startTime - fbTileStart) / fbTileDuration) * TILE_RENDER_WIDTH;
            const fbSrcWidth = ((tile.endTime - tile.startTime) / fbTileDuration) * TILE_RENDER_WIDTH;

            // Apply viewport clipping on top
            const clipRatio = (clippedX - tileX) / tileScreenWidth;
            const clipWidthRatio = clippedWidth / tileScreenWidth;
            const adjSrcLeft = fbSrcLeft + clipRatio * fbSrcWidth;
            const adjSrcWidth = clipWidthRatio * fbSrcWidth;

            ctx.drawImage(
              fallbackBitmap,
              adjSrcLeft, 0, adjSrcWidth, fallbackBitmap.height,
              clippedX, itemY, clippedWidth, itemHeight
            );
            fallbacks++;
            drewFallback = true;

            if (DEBUG_TILES) {
              ctx.strokeStyle = 'rgba(255, 255, 0, 0.8)'; // Yellow = LOD bitmap fallback
              ctx.lineWidth = 1;
              ctx.strokeRect(clippedX, itemY, clippedWidth, itemHeight);
            }
            break;
          }
        }

        // TRY 3: Direct peak rendering (synchronous, slower but no gap)
        if (!drewFallback && tile.peaks.length > 0) {
          drawPeaksDirect(ctx, tile.peaks, clippedX, itemY, clippedWidth, itemHeight, waveformColor);
          fallbacks++;

          if (DEBUG_TILES) {
            ctx.strokeStyle = 'rgba(255, 0, 0, 0.8)'; // Red = direct peaks
            ctx.lineWidth = 1;
            ctx.strokeRect(clippedX, itemY, clippedWidth, itemHeight);
          }
        }

        // Queue async render for correct LOD (will improve quality next frame)
        const renderPromise = tileBitmapCache
          .getOrRender(tileKey, tile.peaks, waveformColor, bitmapHeight)
          .then(() => {
            // Bitmap now cached, will be blitted on next render
          })
          .catch((err) => {
            console.warn('Failed to render tile bitmap:', err);
          });
        pendingRenders.push(renderPromise);

        if (DEBUG_TILES) {
          ctx.fillStyle = 'white';
          ctx.font = '8px monospace';
          ctx.fillText(`T${tileKey.tileIndex}`, clippedX + 2, itemY + 10);
        }
      }
    }

    // Draw separator lines between adjacent/touching items on the same track.
    // Without these, two items that share a boundary look like one big item.
    // Sort items by position, then draw a 1px line wherever one item's end
    // meets another item's start (within a tiny tolerance for float precision).
    const sorted = [...items].sort((a, b) => a.position - b.position);
    for (let i = 0; i < sorted.length - 1; i++) {
      const curr = sorted[i];
      const next = sorted[i + 1];
      const gap = next.position - (curr.position + curr.length);
      // Tolerance: items "touch" if gap is within ~1ms
      if (Math.abs(gap) < 0.002) {
        const boundaryRatio = (next.position - viewportStart) / viewportDuration;
        const bx = Math.round(boundaryRatio * width);
        if (bx >= 0 && bx <= width) {
          ctx.strokeStyle = 'rgba(255, 255, 255, 0.25)';
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(bx + 0.5, itemY);
          ctx.lineTo(bx + 0.5, itemY + itemHeight);
          ctx.stroke();
        }
      }
    }

    // Clear canvas regions NOT covered by any item (prevents stale waveforms)
    clearUncoveredRegions(ctx, drawnRegions, width, height);

    // Debug logging
    if (DEBUG_TILES && (draws > 0 || fallbacks > 0 || pendingRenders.length > 0)) {
      console.log(
        `[Track ${trackIdx}] Draws: ${draws}, Fallbacks: ${fallbacks}, Pending: ${pendingRenders.length}`
      );
    }

    // If there were pending renders, trigger re-render when done
    if (pendingRenders.length > 0) {
      Promise.all(pendingRenders).then(() => {
        setRenderTrigger((n) => n + 1);
      });
    }
  }, [
    trackIdx,
    width,
    height,
    viewportStart,
    viewportEnd,
    items,
    currentLod,
    tileCache,
    trackColor,
    tilesByTake,
    renderTrigger,
  ]);

  return (
    <canvas
      ref={canvasRef}
      className="absolute inset-0"
      style={{
        width,
        height,
        pointerEvents: 'none',
        // GPU compositing hint for smooth scrolling
        transform: 'translateZ(0)',
      }}
    />
  );
}
