/**
 * PeaksCache - LRU cache for waveform peak data
 *
 * Cache key is based on: {itemGUID, takeGUID, length, startOffset, playrate}
 * When any of these change, the cached peaks are invalidated.
 *
 * Uses LRU eviction to prevent unbounded memory growth during long sessions.
 * Default max size: 100 entries (each entry ~10-50KB depending on width).
 */

import type { PeaksResponsePayload } from './WebSocketTypes';

/** Maximum number of cached peak entries before LRU eviction */
const MAX_CACHE_SIZE = 100;

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
  // Map maintains insertion order - we use this for LRU eviction
  private cache = new Map<string, PeaksResponsePayload>();

  /**
   * Get cached peaks for a key (updates LRU order)
   */
  get(key: PeaksCacheKey): PeaksResponsePayload | undefined {
    const keyStr = makeKeyString(key);
    const value = this.cache.get(keyStr);
    if (value !== undefined) {
      // Move to end (most recently used) by re-inserting
      this.cache.delete(keyStr);
      this.cache.set(keyStr, value);
    }
    return value;
  }

  /**
   * Store peaks in cache with LRU eviction
   */
  set(key: PeaksCacheKey, peaks: PeaksResponsePayload): void {
    const keyStr = makeKeyString(key);

    // If key exists, delete it first so it moves to end
    if (this.cache.has(keyStr)) {
      this.cache.delete(keyStr);
    }

    // Evict oldest entries if at capacity
    while (this.cache.size >= MAX_CACHE_SIZE) {
      // Map.keys().next() gives the oldest (first inserted) key
      const oldestKey = this.cache.keys().next().value;
      if (oldestKey) {
        this.cache.delete(oldestKey);
      }
    }

    this.cache.set(keyStr, peaks);
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

  /**
   * Get max cache size (for debugging)
   */
  get maxSize(): number {
    return MAX_CACHE_SIZE;
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
