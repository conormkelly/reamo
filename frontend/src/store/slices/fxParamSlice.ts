/**
 * FX Parameter state slice
 * Manages subscription to FX parameter values for FxParamModal.
 *
 * Similar pattern to routingSlice but with skeleton caching.
 * Skeleton (param names) is cached in LRU to avoid refetching on modal reopen.
 * Values are pushed at 30Hz for subscribed param range.
 */

import type { StateCreator } from 'zustand';
import type { FxParamsEventPayload, FxParamsErrorEventPayload } from '../../core/WebSocketTypes';

/** Single FX parameter info with cached name and live value */
export interface FxParam {
  name: string;
  value: number; // Normalized 0.0-1.0
  formatted: string; // Display string like "-6.0 dB"
}

/** Skeleton entry in LRU cache */
interface SkeletonCacheEntry {
  params: string[];
  hash: number;
}

export interface FxParamSlice {
  // Current subscription
  fxParamSubscription: {
    trackGuid: string;
    fxGuid: string;
    fxName: string;
  } | null;

  // Skeleton (param names) - populated from cache or fetch
  fxParamSkeleton: string[] | null;
  fxParamSkeletonHash: number | null;
  fxParamSkeletonLoading: boolean;
  fxParamSkeletonError: string | null;

  // Live values pushed by backend (keyed by param index)
  fxParamValues: Map<number, { value: number; formatted: string }>;
  fxParamCount: number;

  // Actions
  /** Set up subscription for an FX */
  setFxParamSubscription: (trackGuid: string, fxGuid: string, fxName: string) => void;
  /** Handle incoming trackFxParams event */
  handleFxParamsEvent: (payload: FxParamsEventPayload) => void;
  /** Handle trackFxParamsError event (FX deleted) */
  handleFxParamsError: (payload: FxParamsErrorEventPayload) => void;
  /** Set skeleton from cache or fetch response */
  setFxParamSkeleton: (params: string[], hash: number) => void;
  /** Set skeleton loading state */
  setFxParamSkeletonLoading: (loading: boolean) => void;
  /** Set skeleton error */
  setFxParamSkeletonError: (error: string | null) => void;
  /** Clear subscription and values */
  clearFxParamSubscription: () => void;
  /** Check if skeleton needs refresh (hash mismatch) */
  needsSkeletonRefresh: (paramCount: number, nameHash: number) => boolean;

  // Skeleton cache (internal)
  _fxParamSkeletonCache: Map<string, SkeletonCacheEntry>;
  /** Get cached skeleton for an FX */
  getCachedSkeleton: (trackGuid: string, fxGuid: string) => SkeletonCacheEntry | undefined;
  /** Add skeleton to cache */
  setCachedSkeleton: (trackGuid: string, fxGuid: string, params: string[], hash: number) => void;
}

const SKELETON_CACHE_SIZE = 20;

function getCacheKey(trackGuid: string, fxGuid: string): string {
  return `${trackGuid}:${fxGuid}`;
}

export const createFxParamSlice: StateCreator<FxParamSlice, [], [], FxParamSlice> = (set, get) => ({
  // Initial state
  fxParamSubscription: null,
  fxParamSkeleton: null,
  fxParamSkeletonHash: null,
  fxParamSkeletonLoading: false,
  fxParamSkeletonError: null,
  fxParamValues: new Map(),
  fxParamCount: 0,
  _fxParamSkeletonCache: new Map(),

  // Actions
  setFxParamSubscription: (trackGuid, fxGuid, fxName) => {
    // Check cache for skeleton
    const cached = get().getCachedSkeleton(trackGuid, fxGuid);

    set({
      fxParamSubscription: { trackGuid, fxGuid, fxName },
      fxParamSkeleton: cached?.params ?? null,
      fxParamSkeletonHash: cached?.hash ?? null,
      fxParamSkeletonLoading: !cached, // Loading if not cached
      fxParamSkeletonError: null,
      fxParamValues: new Map(),
      fxParamCount: 0,
    });
  },

  handleFxParamsEvent: (payload) => {
    const sub = get().fxParamSubscription;
    // Ignore if not for current subscription
    if (!sub || sub.trackGuid !== payload.trackGuid || sub.fxGuid !== payload.fxGuid) {
      return;
    }

    // Check if skeleton needs refresh
    if (get().needsSkeletonRefresh(payload.paramCount, payload.nameHash)) {
      // Mark as needing refresh - FxParamModal will refetch
      set({
        fxParamSkeletonLoading: true,
        fxParamSkeletonError: null,
      });
    }

    // Update values from event
    const newValues = new Map(get().fxParamValues);
    for (const [idxStr, [value, formatted]] of Object.entries(payload.values)) {
      const idx = parseInt(idxStr, 10);
      newValues.set(idx, { value, formatted });
    }

    set({
      fxParamValues: newValues,
      fxParamCount: payload.paramCount,
    });
  },

  handleFxParamsError: () => {
    // FX was deleted - clear subscription
    set({
      fxParamSubscription: null,
      fxParamSkeleton: null,
      fxParamSkeletonHash: null,
      fxParamSkeletonLoading: false,
      fxParamSkeletonError: 'FX not found',
      fxParamValues: new Map(),
      fxParamCount: 0,
    });
  },

  setFxParamSkeleton: (params, hash) => {
    const sub = get().fxParamSubscription;
    if (sub) {
      // Update cache
      get().setCachedSkeleton(sub.trackGuid, sub.fxGuid, params, hash);
    }

    set({
      fxParamSkeleton: params,
      fxParamSkeletonHash: hash,
      fxParamSkeletonLoading: false,
      fxParamSkeletonError: null,
    });
  },

  setFxParamSkeletonLoading: (loading) => {
    set({
      fxParamSkeletonLoading: loading,
      fxParamSkeletonError: loading ? null : get().fxParamSkeletonError,
    });
  },

  setFxParamSkeletonError: (error) => {
    set({
      fxParamSkeletonLoading: false,
      fxParamSkeletonError: error,
    });
  },

  clearFxParamSubscription: () => {
    set({
      fxParamSubscription: null,
      fxParamSkeleton: null,
      fxParamSkeletonHash: null,
      fxParamSkeletonLoading: false,
      fxParamSkeletonError: null,
      fxParamValues: new Map(),
      fxParamCount: 0,
    });
  },

  needsSkeletonRefresh: (paramCount, nameHash) => {
    const currentHash = get().fxParamSkeletonHash;
    const currentSkeleton = get().fxParamSkeleton;

    // Need refresh if:
    // 1. No skeleton loaded yet
    // 2. Hash changed (param names changed)
    // 3. Count changed (params added/removed)
    if (!currentSkeleton) return true;
    if (currentHash !== nameHash) return true;
    if (currentSkeleton.length !== paramCount) return true;

    return false;
  },

  // Cache operations
  getCachedSkeleton: (trackGuid, fxGuid) => {
    const key = getCacheKey(trackGuid, fxGuid);
    return get()._fxParamSkeletonCache.get(key);
  },

  setCachedSkeleton: (trackGuid, fxGuid, params, hash) => {
    const key = getCacheKey(trackGuid, fxGuid);
    const cache = new Map(get()._fxParamSkeletonCache);

    // LRU eviction if at capacity
    if (cache.size >= SKELETON_CACHE_SIZE && !cache.has(key)) {
      // Remove oldest entry
      const firstKey = cache.keys().next().value;
      if (firstKey) {
        cache.delete(firstKey);
      }
    }

    // Add/update entry (move to end for LRU)
    cache.delete(key);
    cache.set(key, { params, hash });

    set({ _fxParamSkeletonCache: cache });
  },
});
