/**
 * Peaks state slice - TILE-BASED LOD VERSION
 *
 * Manages tile-based peak data from backend for multi-track waveform rendering.
 * Tiles are chunks of peaks at specific LOD levels that can be cached and assembled.
 *
 * Backend sends tiles with:
 * - takeGuid: identify which take (for cache key)
 * - epoch: cache invalidation signal (changes when source audio edited)
 * - lod: Level of Detail (0-6, see docs/architecture/LOD_LEVELS.md)
 * - tileIndex: position within the item
 * - itemPosition: item start time in project
 * - startTime/endTime: tile bounds relative to item start
 *
 * Tiles are stored in a cache keyed by `${takeGuid}:${epoch}:${lod}:${tileIndex}`
 */

import type { StateCreator } from 'zustand';
import type {
  PeaksEventPayload,
  TileCacheKey,
  LODLevel,
  StereoPeak,
  MonoPeak,
} from '../../core/WebSocketTypes';
import { makeTileCacheKeyString } from '../../core/WebSocketTypes';

/** Subscription mode for peaks */
export type PeaksSubscriptionMode = 'range' | 'guids' | null;

/** Cached tile data (stored without the key fields) */
export interface CachedTile {
  peaks: StereoPeak[] | MonoPeak[];
  channels: 1 | 2;
  startTime: number;   // Relative to item start
  endTime: number;     // Relative to item start
  itemPosition: number; // Absolute project time
}

const MAX_TILE_CACHE_SIZE = 500; // Match backend

export interface PeaksSlice {
  // Subscription state
  peaksSubscriptionMode: PeaksSubscriptionMode;
  peaksSubscribedRange: { start: number; end: number } | null;
  peaksSubscribedGuids: string[] | null;

  // Current LOD level (from last viewport update)
  currentLod: LODLevel;

  // Tile cache: key string → cached tile data
  tileCache: Map<string, CachedTile>;

  // Index: takeGuid → array of cache key strings (for fast lookup)
  tilesByTake: Map<string, string[]>;

  // Actions
  setPeaksSubscriptionRange: (start: number, end: number) => void;
  setPeaksSubscriptionGuids: (guids: string[]) => void;
  handlePeaksEvent: (payload: PeaksEventPayload) => void;
  clearPeaksSubscription: () => void;
  setCurrentLod: (lod: LODLevel) => void;

  // Selectors
  /** Get all cached tiles for a take at current LOD */
  getTilesForTake: (takeGuid: string) => CachedTile[];

  /** Check if any tiles exist for a take at the given LOD */
  hasTilesForTake: (takeGuid: string, lod?: LODLevel) => boolean;

  /**
   * Assemble peaks for an item within a viewport.
   * Concatenates tiles that overlap the visible range.
   * Returns null if no tiles available.
   */
  assemblePeaksForViewport: (
    takeGuid: string,
    itemPosition: number,
    itemLength: number,
    viewportStart: number,
    viewportEnd: number
  ) => StereoPeak[] | MonoPeak[] | null;
}

export const createPeaksSlice: StateCreator<PeaksSlice, [], [], PeaksSlice> = (set, get) => ({
  // Initial state
  peaksSubscriptionMode: null,
  peaksSubscribedRange: null,
  peaksSubscribedGuids: null,
  currentLod: 1, // Default to medium
  tileCache: new Map(),
  tilesByTake: new Map(),

  // Actions
  setPeaksSubscriptionRange: (start, end) =>
    set({
      peaksSubscriptionMode: 'range',
      peaksSubscribedRange: { start, end },
      peaksSubscribedGuids: null,
    }),

  setPeaksSubscriptionGuids: (guids) =>
    set({
      peaksSubscriptionMode: 'guids',
      peaksSubscribedRange: null,
      peaksSubscribedGuids: guids,
    }),

  handlePeaksEvent: (payload) =>
    set((state) => {
      const newTileCache = new Map(state.tileCache);
      const newTilesByTake = new Map(state.tilesByTake);
      let newLod = state.currentLod;

      // Process incoming tiles
      for (const tile of payload.tiles) {
        const key: TileCacheKey = {
          takeGuid: tile.takeGuid,
          epoch: tile.epoch,
          lod: tile.lod,
          tileIndex: tile.tileIndex,
        };
        const keyStr = makeTileCacheKeyString(key);

        // Store tile data (without key fields to save memory)
        newTileCache.set(keyStr, {
          peaks: tile.peaks,
          channels: tile.channels,
          startTime: tile.startTime,
          endTime: tile.endTime,
          itemPosition: tile.itemPosition,
        });

        // Update index
        const existing = newTilesByTake.get(tile.takeGuid) ?? [];
        if (!existing.includes(keyStr)) {
          existing.push(keyStr);
          newTilesByTake.set(tile.takeGuid, existing);
        }

        // Update current LOD from tile (all tiles in event share same LOD)
        newLod = tile.lod;
      }

      // LRU eviction if cache too large
      while (newTileCache.size > MAX_TILE_CACHE_SIZE) {
        const oldestKey = newTileCache.keys().next().value;
        if (oldestKey) {
          newTileCache.delete(oldestKey);
          // Also remove from index
          for (const [takeGuid, keys] of newTilesByTake) {
            const idx = keys.indexOf(oldestKey);
            if (idx !== -1) {
              keys.splice(idx, 1);
              if (keys.length === 0) {
                newTilesByTake.delete(takeGuid);
              }
              break;
            }
          }
        }
      }

      return {
        tileCache: newTileCache,
        tilesByTake: newTilesByTake,
        currentLod: newLod,
      };
    }),

  clearPeaksSubscription: () =>
    set({
      peaksSubscriptionMode: null,
      peaksSubscribedRange: null,
      peaksSubscribedGuids: null,
      tileCache: new Map(),
      tilesByTake: new Map(),
    }),

  setCurrentLod: (lod) => set({ currentLod: lod }),

  // Selectors
  getTilesForTake: (takeGuid) => {
    const state = get();
    const keyStrings = state.tilesByTake.get(takeGuid) ?? [];
    const tiles: CachedTile[] = [];

    for (const keyStr of keyStrings) {
      // Filter to current LOD
      if (keyStr.includes(`:${state.currentLod}:`)) {
        const tile = state.tileCache.get(keyStr);
        if (tile) tiles.push(tile);
      }
    }

    // Sort by startTime for ordered assembly
    return tiles.sort((a, b) => a.startTime - b.startTime);
  },

  hasTilesForTake: (takeGuid, lod) => {
    const state = get();
    const targetLod = lod ?? state.currentLod;
    const keyStrings = state.tilesByTake.get(takeGuid) ?? [];
    return keyStrings.some((keyStr) => keyStr.includes(`:${targetLod}:`));
  },

  assemblePeaksForViewport: (takeGuid, itemPosition, itemLength, viewportStart, viewportEnd) => {
    const state = get();
    const keyStrings = state.tilesByTake.get(takeGuid) ?? [];

    // Get tiles for current LOD, sorted by startTime
    const tiles: CachedTile[] = [];
    for (const keyStr of keyStrings) {
      if (keyStr.includes(`:${state.currentLod}:`)) {
        const tile = state.tileCache.get(keyStr);
        if (tile) tiles.push(tile);
      }
    }

    if (tiles.length === 0) return null;

    tiles.sort((a, b) => a.startTime - b.startTime);

    // Calculate visible range relative to item start
    const visibleStart = Math.max(0, viewportStart - itemPosition);
    const visibleEnd = Math.min(itemLength, viewportEnd - itemPosition);

    if (visibleStart >= visibleEnd) return null;

    // Concatenate peaks from tiles covering visible range
    // Note: All tiles for a take have the same channel count, so cast is safe
    const assembled: StereoPeak[] | MonoPeak[] = [];

    for (const tile of tiles) {
      // Skip tiles completely outside visible range
      if (tile.endTime <= visibleStart || tile.startTime >= visibleEnd) continue;

      // Calculate slice bounds within this tile
      const tileVisibleStart = Math.max(tile.startTime, visibleStart);
      const tileVisibleEnd = Math.min(tile.endTime, visibleEnd);

      // Calculate peak indices to include
      const tileDuration = tile.endTime - tile.startTime;
      const peaksPerSecond = tile.peaks.length / tileDuration;

      const startPeakIdx = Math.floor((tileVisibleStart - tile.startTime) * peaksPerSecond);
      const endPeakIdx = Math.ceil((tileVisibleEnd - tile.startTime) * peaksPerSecond);

      // Clamp to valid range
      const clampedStart = Math.max(0, startPeakIdx);
      const clampedEnd = Math.min(tile.peaks.length, endPeakIdx);

      // Cast needed because TypeScript can't narrow union arrays from spread
      (assembled as (StereoPeak | MonoPeak)[]).push(...tile.peaks.slice(clampedStart, clampedEnd));
    }

    return assembled.length > 0 ? assembled : null;
  },
});
