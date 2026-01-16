/**
 * Stable Empty References
 *
 * Zustand 5 selectors create new references for fallback values like `?? {}` or `?? []`
 * on every render, causing unnecessary re-renders. These stable singletons prevent that.
 *
 * Usage:
 * ```typescript
 * import { EMPTY_TRACKS, EMPTY_ARRAY } from '../store/stableRefs';
 *
 * // BEFORE (creates new object each render):
 * const tracks = useReaperStore((state) => state?.tracks ?? {});
 *
 * // AFTER (stable reference):
 * const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);
 * ```
 */

import type { Track, Region, Marker } from '../core/types';
import type { WSItem, SkeletonTrack } from '../core/WebSocketTypes';

/** Stable empty tracks record */
export const EMPTY_TRACKS: Record<number, Track> = Object.freeze({});

/** Stable empty regions array */
export const EMPTY_REGIONS: readonly Region[] = Object.freeze([]);

/** Stable empty markers array */
export const EMPTY_MARKERS: readonly Marker[] = Object.freeze([]);

/** Stable empty items array */
export const EMPTY_ITEMS: readonly WSItem[] = Object.freeze([]);

/** Stable empty skeleton array */
export const EMPTY_SKELETON: readonly SkeletonTrack[] = Object.freeze([]);

/** Stable empty GUID-to-index map */
export const EMPTY_GUID_MAP: ReadonlyMap<string, number> = Object.freeze(new Map());

/** Stable empty string array (for GUID lists, etc.) */
export const EMPTY_STRING_ARRAY: readonly string[] = Object.freeze([]);
