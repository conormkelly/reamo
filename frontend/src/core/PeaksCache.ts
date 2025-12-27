/**
 * PeaksCache - Caches waveform peak data to avoid refetching
 *
 * Cache key is based on: {itemGUID, takeGUID, length, startOffset, playrate}
 * When any of these change, the cached peaks are invalidated.
 */

import type { PeaksResponsePayload } from './WebSocketTypes';

export interface PeaksCacheKey {
  itemGUID: string;
  takeGUID: string;
  length: number;
  startOffset: number;
  playrate: number;
}

/**
 * Create a string key from cache key components
 */
function makeKeyString(key: PeaksCacheKey): string {
  // Round numbers to avoid floating point precision issues
  const length = key.length.toFixed(6);
  const startOffset = key.startOffset.toFixed(6);
  const playrate = key.playrate.toFixed(6);
  return `${key.itemGUID}:${key.takeGUID}:${length}:${startOffset}:${playrate}`;
}

class PeaksCacheImpl {
  private cache = new Map<string, PeaksResponsePayload>();

  /**
   * Get cached peaks for a key
   */
  get(key: PeaksCacheKey): PeaksResponsePayload | undefined {
    return this.cache.get(makeKeyString(key));
  }

  /**
   * Store peaks in cache
   */
  set(key: PeaksCacheKey, peaks: PeaksResponsePayload): void {
    this.cache.set(makeKeyString(key), peaks);
  }

  /**
   * Check if peaks are cached for a key
   */
  has(key: PeaksCacheKey): boolean {
    return this.cache.has(makeKeyString(key));
  }

  /**
   * Invalidate all cache entries for a specific item
   * Call this when an item's properties change
   */
  invalidateItem(itemGUID: string): void {
    for (const [keyStr] of this.cache) {
      if (keyStr.startsWith(itemGUID + ':')) {
        this.cache.delete(keyStr);
      }
    }
  }

  /**
   * Clear entire cache
   */
  clear(): void {
    this.cache.clear();
  }

  /**
   * Get cache size (for debugging)
   */
  get size(): number {
    return this.cache.size;
  }
}

// Singleton instance
export const peaksCache = new PeaksCacheImpl();

/**
 * Build a cache key from an item and its active take
 */
export function buildPeaksCacheKey(
  itemGUID: string,
  takeGUID: string,
  length: number,
  startOffset: number,
  playrate: number
): PeaksCacheKey {
  return { itemGUID, takeGUID, length, startOffset, playrate };
}
