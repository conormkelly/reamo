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
 * - Skip rendering during gestures (CSS transform handles visual)
 * - GPU compositing via translateZ(0)
 * - ImageBitmap blitting is GPU-accelerated
 *
 * Per research doc: "Pre-render waveforms to ImageBitmap for GPU-accelerated blitting"
 * ctx.drawImage(cachedBitmap, ...) is blazing fast compared to fillRect loops.
 */

import { useRef, useEffect, useState, type ReactElement } from 'react';
import type { WSItem, TileCacheKey, LODLevel } from '../../core/WebSocketTypes';
import { tileBitmapCache, TILE_RENDER_WIDTH } from '../../core/TileBitmapCache';
import { reaperColorToRgba, getContrastColor } from '../../utils';
import { useReaperStore } from '../../store';

// Default item color when no color set
const DEFAULT_ITEM_COLOR = 'rgba(129, 137, 137, 0.6)';

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

/** Get item color with fallback */
function getItemColor(item: WSItem, opacity: number = 0.6): string {
  if (!item.color) return DEFAULT_ITEM_COLOR;
  return reaperColorToRgba(item.color, opacity) ?? DEFAULT_ITEM_COLOR;
}

/** Get waveform color that contrasts with item background */
function getWaveformColor(item: WSItem): string {
  const contrastBase = item.color ? getContrastColor(item.color) : 'white';
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

  // Item layout constants (matches MultiTrackLanes)
  const itemTopPercent = 10;
  const itemHeightPercent = 80;
  const itemY = (itemTopPercent / 100) * height;
  const itemHeight = (itemHeightPercent / 100) * height;

  useEffect(() => {
    // Note: We MUST redraw on every viewport change (including during pan gestures)
    // because items need to be at different pixel positions. The CSS scaleX transform
    // only helps during pinch-zoom, not during pan. ImageBitmap blitting is fast enough
    // for 60fps redraws.

    const canvas = canvasRef.current;
    if (!canvas || width === 0 || height === 0) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // 1x DPR for waveforms (saves 4x memory, per architecture doc)
    canvas.width = width;
    canvas.height = height;

    // Clear canvas
    ctx.clearRect(0, 0, width, height);

    const viewportDuration = viewportEnd - viewportStart;
    if (viewportDuration <= 0) return;

    // Track pending bitmap renders for async re-render
    const pendingRenders: Promise<void>[] = [];

    // Render each item
    for (const item of items) {
      const itemStart = item.position;
      const itemEnd = item.position + item.length;

      // Skip items completely outside viewport
      if (itemEnd <= viewportStart || itemStart >= viewportEnd) continue;

      // Calculate item screen position (clipped to viewport)
      const leftRatio = Math.max(0, (itemStart - viewportStart) / viewportDuration);
      const rightRatio = Math.min(1, (itemEnd - viewportStart) / viewportDuration);
      const itemX = leftRatio * width;
      const itemWidth = (rightRatio - leftRatio) * width;

      // Draw item background
      ctx.fillStyle = getItemColor(item);
      ctx.fillRect(itemX, itemY, itemWidth, itemHeight);

      // Draw selection border
      if (item.selected) {
        ctx.strokeStyle = '#3b82f6'; // --color-primary
        ctx.lineWidth = 2;
        ctx.strokeRect(itemX + 1, itemY + 1, itemWidth - 2, itemHeight - 2);
      }

      // Skip MIDI items and items without take GUID
      if (item.activeTakeIsMidi || !item.activeTakeGuid) continue;

      // Get tiles for this item's take at current LOD
      const takeKeyStrings = tilesByTake.get(item.activeTakeGuid) ?? [];
      const waveformColor = getWaveformColor(item);
      const bitmapHeight = Math.round(itemHeight);

      for (const keyStr of takeKeyStrings) {
        // Filter to current LOD
        if (!keyStr.includes(`:${currentLod}:`)) continue;

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
        const tileX = tileLeftRatio * width;
        const tileScreenWidth = (tileRightRatio - tileLeftRatio) * width;

        // Clip tile to item bounds (tiles shouldn't extend past item visually)
        const clippedX = Math.max(tileX, itemX);
        const clippedRight = Math.min(tileX + tileScreenWidth, itemX + itemWidth);
        const clippedWidth = clippedRight - clippedX;

        if (clippedWidth <= 0) continue;

        // Parse tile cache key for bitmap lookup
        const tileKey = parseTileCacheKey(keyStr);
        if (!tileKey) continue;

        // Try to get cached bitmap (sync path - fast)
        const cachedBitmap = tileBitmapCache.get(tileKey, waveformColor, bitmapHeight);

        if (cachedBitmap) {
          // GPU-accelerated blit! This is the fast path per architecture doc.
          // Source rect: portion of bitmap that maps to clipped screen area
          const srcClipLeft = ((clippedX - tileX) / tileScreenWidth) * TILE_RENDER_WIDTH;
          const srcClipWidth = (clippedWidth / tileScreenWidth) * TILE_RENDER_WIDTH;

          ctx.drawImage(
            cachedBitmap,
            srcClipLeft,
            0,
            srcClipWidth,
            cachedBitmap.height, // source rect
            clippedX,
            itemY,
            clippedWidth,
            itemHeight // dest rect
          );
        } else {
          // Async render bitmap, then trigger re-render
          const renderPromise = tileBitmapCache
            .getOrRender(tileKey, tile.peaks, waveformColor, bitmapHeight)
            .then(() => {
              // Bitmap now cached, will be blitted on next render
            })
            .catch((err) => {
              console.warn('Failed to render tile bitmap:', err);
            });
          pendingRenders.push(renderPromise);
        }
      }
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
