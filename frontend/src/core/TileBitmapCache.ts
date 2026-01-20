/**
 * TileBitmapCache - Pre-rendered waveform tiles for GPU-accelerated blitting
 *
 * Renders peak data to ImageBitmap via OffscreenCanvas (Safari 17+).
 * ImageBitmaps can be drawn to canvas via drawImage() without re-parsing,
 * enabling 60fps timeline scrolling on iPad.
 *
 * Memory management:
 * - LRU eviction at 200 tiles (~50MB budget)
 * - Always call bitmap.close() on eviction to free GPU memory
 * - Cache key includes LOD + color so same tile can have different colors
 *
 * @example
 * ```ts
 * // Get or render a tile bitmap
 * const bitmap = await tileBitmapCache.getOrRender(
 *   cacheKey,
 *   peaks,
 *   'rgba(255,255,255,0.85)',
 *   64 // height
 * );
 *
 * // Blit to canvas
 * ctx.drawImage(bitmap, destX, 0, destWidth, height);
 * ```
 */

import type { StereoPeak, MonoPeak, TileCacheKey } from './WebSocketTypes';
import { makeTileCacheKeyString } from './WebSocketTypes';

/** Fixed width for rendered tile bitmaps (pixels) */
const TILE_RENDER_WIDTH = 512;

/** Maximum cached bitmaps (~50MB at 512x64 RGBA) */
const MAX_CACHE_SIZE = 200;

/** Check if peaks are stereo */
function isStereo(peaks: StereoPeak[] | MonoPeak[]): peaks is StereoPeak[] {
  return peaks.length > 0 && typeof peaks[0] === 'object' && 'l' in peaks[0];
}

/**
 * Render peaks to an ImageBitmap using OffscreenCanvas
 * Falls back to regular canvas if OffscreenCanvas unavailable
 */
async function renderPeaksToBitmap(
  peaks: StereoPeak[] | MonoPeak[],
  color: string,
  height: number
): Promise<ImageBitmap> {
  const width = TILE_RENDER_WIDTH;

  // Use OffscreenCanvas if available (Safari 17+, all modern browsers)
  // Falls back to regular canvas for older browsers
  const canvas =
    typeof OffscreenCanvas !== 'undefined'
      ? new OffscreenCanvas(width, height)
      : document.createElement('canvas');

  if (!(canvas instanceof OffscreenCanvas)) {
    canvas.width = width;
    canvas.height = height;
  }

  const ctx = canvas.getContext('2d') as CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;
  if (!ctx) throw new Error('Failed to get canvas context');

  // Clear (transparent background - item color shows through)
  ctx.clearRect(0, 0, width, height);

  // Draw waveform
  ctx.fillStyle = color;
  const centerY = height / 2;
  const sampleWidth = width / peaks.length;

  for (let i = 0; i < peaks.length; i++) {
    const peak = peaks[i];
    let minVal: number;
    let maxVal: number;

    if (isStereo(peaks)) {
      const stereoPeak = peak as StereoPeak;
      // Combine L+R into single peak (average) for cramped lanes
      minVal = (stereoPeak.l[0] + stereoPeak.r[0]) / 2;
      maxVal = (stereoPeak.l[1] + stereoPeak.r[1]) / 2;
    } else {
      const monoPeak = peak as MonoPeak;
      minVal = monoPeak[0];
      maxVal = monoPeak[1];
    }

    const x = i * sampleWidth;
    const topY = centerY - maxVal * centerY;
    const bottomY = centerY - minVal * centerY;

    // Ensure minimum 1px height so silent sections show as thin centered line
    const peakHeight = Math.max(bottomY - topY, 1);
    const adjustedTopY = peakHeight === 1 ? centerY - 0.5 : topY;

    ctx.fillRect(x, adjustedTopY, Math.max(sampleWidth - 0.5, 1), peakHeight);
  }

  // Convert to ImageBitmap for GPU-accelerated blitting
  if (canvas instanceof OffscreenCanvas) {
    return canvas.transferToImageBitmap();
  } else {
    return createImageBitmap(canvas);
  }
}

/** Extended cache key that includes color (same tile, different colors) */
interface BitmapCacheKey extends TileCacheKey {
  color: string;
  height: number;
}

/** Create string key for bitmap cache */
function makeBitmapCacheKeyString(key: BitmapCacheKey): string {
  return `${makeTileCacheKeyString(key)}:${key.color}:${key.height}`;
}

/**
 * LRU cache for pre-rendered waveform tile bitmaps
 */
class TileBitmapCacheImpl {
  private cache = new Map<string, ImageBitmap>();
  private accessOrder: string[] = []; // For LRU tracking

  /**
   * Get cached bitmap or render and cache it
   */
  async getOrRender(
    tileKey: TileCacheKey,
    peaks: StereoPeak[] | MonoPeak[],
    color: string,
    height: number
  ): Promise<ImageBitmap> {
    const key: BitmapCacheKey = { ...tileKey, color, height };
    const keyStr = makeBitmapCacheKeyString(key);

    // Check cache
    const existing = this.cache.get(keyStr);
    if (existing) {
      // Move to end of access order (most recently used)
      this.touchKey(keyStr);
      return existing;
    }

    // Render new bitmap
    const bitmap = await renderPeaksToBitmap(peaks, color, height);

    // Evict if at capacity
    while (this.cache.size >= MAX_CACHE_SIZE) {
      this.evictOldest();
    }

    // Cache the bitmap
    this.cache.set(keyStr, bitmap);
    this.accessOrder.push(keyStr);

    return bitmap;
  }

  /**
   * Get cached bitmap (sync, returns null if not cached)
   */
  get(tileKey: TileCacheKey, color: string, height: number): ImageBitmap | null {
    const key: BitmapCacheKey = { ...tileKey, color, height };
    const keyStr = makeBitmapCacheKeyString(key);
    const bitmap = this.cache.get(keyStr);
    if (bitmap) {
      this.touchKey(keyStr);
      return bitmap;
    }
    return null;
  }

  /**
   * Check if bitmap is cached
   */
  has(tileKey: TileCacheKey, color: string, height: number): boolean {
    const key: BitmapCacheKey = { ...tileKey, color, height };
    return this.cache.has(makeBitmapCacheKeyString(key));
  }

  /**
   * Clear all cached bitmaps (e.g., on disconnect)
   */
  clear(): void {
    // Free GPU memory for all bitmaps
    for (const bitmap of this.cache.values()) {
      bitmap.close();
    }
    this.cache.clear();
    this.accessOrder = [];
  }

  /**
   * Get cache size for debugging
   */
  get size(): number {
    return this.cache.size;
  }

  /** Move key to end of access order */
  private touchKey(keyStr: string): void {
    const idx = this.accessOrder.indexOf(keyStr);
    if (idx !== -1) {
      this.accessOrder.splice(idx, 1);
    }
    this.accessOrder.push(keyStr);
  }

  /** Evict least recently used bitmap */
  private evictOldest(): void {
    const oldestKey = this.accessOrder.shift();
    if (oldestKey) {
      const bitmap = this.cache.get(oldestKey);
      if (bitmap) {
        bitmap.close(); // Free GPU memory
        this.cache.delete(oldestKey);
      }
    }
  }
}

/** Singleton instance */
export const tileBitmapCache = new TileBitmapCacheImpl();

/** Re-export types for consumers */
export type { BitmapCacheKey };
export { TILE_RENDER_WIDTH };
