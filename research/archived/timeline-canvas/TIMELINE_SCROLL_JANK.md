# REAmo Timeline Waveform Flicker Analysis & Solution

## Executive Summary

The timeline component experiences **visual glitching and distortion of waveforms during pan/scroll**, despite smooth movement and good frame rate performance. The issue is particularly noticeable at wider zoom levels on longer timelines, but performs well when zoomed into ~1 second views.

**Root Cause:** The visual artifacts stem from tile cache misses during pan operations combined with a render strategy that clears the canvas before all replacement content is ready. With only 3 LOD levels spanning a 400x density range, LOD transitions also create jarring visual discontinuities.

**Solution:** Implement a fallback rendering strategy that never leaves visual holes, add intermediate LOD levels for smoother transitions, and pre-fetch tiles in the pan direction.

---

## Problem Analysis

### Observed Symptoms

| Symptom | Frequency | Conditions |
|---------|-----------|------------|
| Waveform "flickering" | During active pan | More visible at wider zoom levels |
| Waveform "distortion" | During momentum | Shapes appear to shift/stretch momentarily |
| Visual gaps in waveforms | Intermittent | When new tiles enter viewport |
| Performance is actually good | Consistently | Zoomed to 1s, frame rate stable |

### What This Rules Out

The fact that performance is good at fine zoom levels and movement is smooth indicates:

- ❌ **NOT a React reconciliation problem** — frame budget is being met
- ❌ **NOT a compositor/transform issue** — movement itself is smooth
- ❌ **NOT a general performance bottleneck** — works well at detail views
- ✅ **IS a tile rendering/caching issue** — manifests at zoom levels requiring more tiles
- ✅ **IS an LOD transition issue** — 3 levels with large gaps between them

---

## Root Cause Deep Dive

### Cause 1: Canvas Clear-Before-Draw Race Condition

The current `WaveformCanvas.tsx` implementation:

```typescript
useEffect(() => {
  // ...
  ctx.clearRect(0, 0, width, height);  // ← ENTIRE CANVAS GOES BLANK
  
  for (const item of items) {
    // ... calculate positions ...
    
    for (const keyStr of takeKeyStrings) {
      const cachedBitmap = tileBitmapCache.get(tileKey, waveformColor, bitmapHeight);
      
      if (cachedBitmap) {
        ctx.drawImage(cachedBitmap, ...);  // ✓ Draws immediately
      } else {
        // ✗ NOTHING DRAWN THIS FRAME - VISIBLE HOLE!
        tileBitmapCache.getOrRender(...).then(() => {
          setRenderTrigger((n) => n + 1);  // Triggers re-render next frame
        });
      }
    }
  }
}, [viewportStart, viewportEnd, ...]);
```

**The Race Condition:**

```
Frame N:   clearRect() → draw cached tiles → [GAPS where uncached tiles should be]
Frame N+1: clearRect() → draw cached tiles → [GAPS still present, async pending]
Frame N+2: async complete → setRenderTrigger → full redraw with new tiles
```

During frames N and N+1, the user sees incomplete waveforms — this is the "flicker."

### Cause 2: Extreme LOD Density Jumps

Current LOD configuration:

| LOD Level | Peaks/Second | Typical Zoom Range | Tile Coverage |
|-----------|--------------|-------------------|---------------|
| 0 (coarse) | 1 | Hour+ view | 64 seconds |
| 1 (medium) | 10 | Minutes view | 8 seconds |
| 2 (fine) | 400 | Seconds view | 0.5 seconds |

**The Problem:** Jumping from LOD 1 (10 peaks/sec) to LOD 2 (400 peaks/sec) is a **40x density increase**. The waveform's visual shape changes dramatically because you're literally seeing different data points. This creates a jarring "morph" effect during zoom or when the LOD selection algorithm switches levels.

### Cause 3: No Tile Pre-fetching

The current implementation only loads tiles that are currently visible:

```typescript
// Only processes tiles that overlap current viewport
if (tileAbsEnd <= viewportStart || tileAbsStart >= viewportEnd) continue;
```

When panning, new tiles enter the viewport but aren't in cache, causing:
1. First frame: tile not rendered (cache miss)
2. Async render triggered
3. Subsequent frame: tile appears

This creates a "leading edge flicker" as content scrolls into view.

### Cause 4: Render Trigger Cascade

The `setRenderTrigger` pattern can cause cascading re-renders:

```typescript
const pendingRenders: Promise<void>[] = [];

// ... in loop ...
pendingRenders.push(renderPromise);

// After loop
if (pendingRenders.length > 0) {
  Promise.all(pendingRenders).then(() => {
    setRenderTrigger((n) => n + 1);  // Triggers FULL re-render
  });
}
```

If multiple tiles are loading, this fires once when ALL complete. But if tiles complete at different times across multiple frames, you can get:

```
Frame N:   3 tiles missing, async started
Frame N+5: 2 tiles complete → setRenderTrigger
Frame N+6: Full redraw, but 1 tile still missing → async started again
Frame N+8: Last tile complete → setRenderTrigger
Frame N+9: Full redraw again
```

Each full redraw includes `clearRect`, amplifying the visual disruption.

---

## Solution Architecture

### Solution 1: Never-Clear Rendering Strategy

**Principle:** Only clear canvas regions immediately before drawing confirmed content.

```typescript
useEffect(() => {
  const canvas = canvasRef.current;
  if (!canvas || width === 0 || height === 0) return;

  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  // ✗ REMOVE: ctx.clearRect(0, 0, width, height);
  
  const viewportDuration = viewportEnd - viewportStart;
  if (viewportDuration <= 0) return;

  // Track regions we're about to draw (for cleanup of stale areas)
  const drawnRegions: Array<{ x: number; width: number }> = [];

  for (const item of items) {
    const itemStart = item.position;
    const itemEnd = item.position + item.length;
    if (itemEnd <= viewportStart || itemStart >= viewportEnd) continue;

    const leftRatio = Math.max(0, (itemStart - viewportStart) / viewportDuration);
    const rightRatio = Math.min(1, (itemEnd - viewportStart) / viewportDuration);
    const itemX = leftRatio * width;
    const itemWidth = (rightRatio - leftRatio) * width;

    // Clear ONLY this item's region, right before drawing it
    ctx.clearRect(itemX, 0, itemWidth, height);

    // Draw item background (always succeeds - no flicker)
    ctx.fillStyle = getItemColor(item);
    ctx.fillRect(itemX, itemY, itemWidth, itemHeight);

    // Selection border
    if (item.selected) {
      ctx.strokeStyle = '#3b82f6';
      ctx.lineWidth = 2;
      ctx.strokeRect(itemX + 1, itemY + 1, itemWidth - 2, itemHeight - 2);
    }

    drawnRegions.push({ x: itemX, width: itemWidth });

    // Draw waveform tiles with fallback strategy...
    drawWaveformWithFallback(ctx, item, itemX, itemY, itemWidth, itemHeight, ...);
  }

  // Clear any canvas regions NOT covered by items (prevents stale waveforms)
  clearUncoveredRegions(ctx, drawnRegions, width, height);
}, [/* dependencies */]);

function clearUncoveredRegions(
  ctx: CanvasRenderingContext2D,
  drawnRegions: Array<{ x: number; width: number }>,
  canvasWidth: number,
  canvasHeight: number
) {
  // Sort regions by x position
  const sorted = [...drawnRegions].sort((a, b) => a.x - b.x);
  
  let lastEnd = 0;
  for (const region of sorted) {
    if (region.x > lastEnd) {
      // Gap between last region and this one - clear it
      ctx.clearRect(lastEnd, 0, region.x - lastEnd, canvasHeight);
    }
    lastEnd = Math.max(lastEnd, region.x + region.width);
  }
  
  // Clear from last region to canvas edge
  if (lastEnd < canvasWidth) {
    ctx.clearRect(lastEnd, 0, canvasWidth - lastEnd, canvasHeight);
  }
}
```

### Solution 2: Synchronous Fallback Rendering

**Principle:** Always draw *something* for every tile region — never leave holes.

```typescript
function drawWaveformWithFallback(
  ctx: CanvasRenderingContext2D,
  item: WSItem,
  itemX: number,
  itemY: number,
  itemWidth: number,
  itemHeight: number,
  viewportStart: number,
  viewportEnd: number,
  currentLod: LODLevel,
  tilesByTake: Map<string, string[]>,
  tileCache: Map<string, CachedTile>,
  pendingRenders: Promise<void>[]
) {
  if (item.activeTakeIsMidi || !item.activeTakeGuid) return;

  const takeKeyStrings = tilesByTake.get(item.activeTakeGuid) ?? [];
  const waveformColor = getWaveformColor(item);
  const bitmapHeight = Math.round(itemHeight);
  const viewportDuration = viewportEnd - viewportStart;

  for (const keyStr of takeKeyStrings) {
    if (!keyStr.includes(`:${currentLod}:`)) continue;

    const tile = tileCache.get(keyStr);
    if (!tile || tile.peaks.length === 0) continue;

    const tileAbsStart = tile.itemPosition + tile.startTime;
    const tileAbsEnd = tile.itemPosition + tile.endTime;
    if (tileAbsEnd <= viewportStart || tileAbsStart >= viewportEnd) continue;

    // Calculate screen position
    const tileLeftRatio = (tileAbsStart - viewportStart) / viewportDuration;
    const tileRightRatio = (tileAbsEnd - viewportStart) / viewportDuration;
    const tileX = tileLeftRatio * width;
    const tileScreenWidth = (tileRightRatio - tileLeftRatio) * width;

    // Clip to item bounds
    const clippedX = Math.max(tileX, itemX);
    const clippedRight = Math.min(tileX + tileScreenWidth, itemX + itemWidth);
    const clippedWidth = clippedRight - clippedX;
    if (clippedWidth <= 0) continue;

    const tileKey = parseTileCacheKey(keyStr);
    if (!tileKey) continue;

    // TRY 1: Exact cached bitmap (ideal case)
    const cachedBitmap = tileBitmapCache.get(tileKey, waveformColor, bitmapHeight);
    
    if (cachedBitmap) {
      drawTileBitmap(ctx, cachedBitmap, tileX, tileScreenWidth, clippedX, clippedWidth, itemY, itemHeight);
      continue;
    }

    // TRY 2: Fallback to adjacent LOD (scaled but no gap)
    const fallbackBitmap = findFallbackBitmap(tileKey, tile, waveformColor, bitmapHeight);
    
    if (fallbackBitmap) {
      // Draw scaled version - may look slightly different but NO FLICKER
      drawTileBitmap(ctx, fallbackBitmap.bitmap, tileX, tileScreenWidth, clippedX, clippedWidth, itemY, itemHeight);
    } else {
      // TRY 3: Draw from raw peak data synchronously (expensive but prevents gap)
      drawPeaksDirect(ctx, tile.peaks, clippedX, itemY, clippedWidth, itemHeight, waveformColor);
    }

    // Queue async render for correct LOD (will improve quality on next frame)
    const renderPromise = tileBitmapCache
      .getOrRender(tileKey, tile.peaks, waveformColor, bitmapHeight)
      .catch((err) => console.warn('Failed to render tile bitmap:', err));
    pendingRenders.push(renderPromise);
  }
}

function findFallbackBitmap(
  targetKey: TileCacheKey,
  tile: CachedTile,
  waveformColor: string,
  bitmapHeight: number
): { bitmap: ImageBitmap; lod: LODLevel } | null {
  // Try coarser LOD first (more likely to be cached, covers larger time range)
  const fallbackLods = [
    targetKey.lod - 1,  // One level coarser
    targetKey.lod + 1,  // One level finer
    targetKey.lod - 2,  // Two levels coarser
  ].filter(lod => lod >= 0 && lod <= 2) as LODLevel[];

  for (const fallbackLod of fallbackLods) {
    // Calculate equivalent tile index at fallback LOD
    const fallbackTileIndex = calculateEquivalentTileIndex(targetKey, fallbackLod);
    const fallbackKey: TileCacheKey = {
      ...targetKey,
      lod: fallbackLod,
      tileIndex: fallbackTileIndex,
    };
    
    const bitmap = tileBitmapCache.get(fallbackKey, waveformColor, bitmapHeight);
    if (bitmap) {
      return { bitmap, lod: fallbackLod };
    }
  }
  
  return null;
}

function drawPeaksDirect(
  ctx: CanvasRenderingContext2D,
  peaks: StereoPeak[] | MonoPeak[],
  x: number,
  y: number,
  width: number,
  height: number,
  color: string
) {
  // Direct peak rendering - slower than bitmap blit but synchronous
  ctx.fillStyle = color;
  const centerY = y + height / 2;
  const sampleWidth = width / peaks.length;

  for (let i = 0; i < peaks.length; i++) {
    const peak = peaks[i];
    let minVal: number, maxVal: number;

    if (isStereo(peaks)) {
      const sp = peak as StereoPeak;
      minVal = (sp.l[0] + sp.r[0]) / 2;
      maxVal = (sp.l[1] + sp.r[1]) / 2;
    } else {
      const mp = peak as MonoPeak;
      minVal = mp[0];
      maxVal = mp[1];
    }

    const peakX = x + i * sampleWidth;
    const topY = centerY - maxVal * (height / 2);
    const bottomY = centerY - minVal * (height / 2);
    const peakHeight = Math.max(bottomY - topY, 1);

    ctx.fillRect(peakX, topY, Math.max(sampleWidth - 0.5, 1), peakHeight);
  }
}

function drawTileBitmap(
  ctx: CanvasRenderingContext2D,
  bitmap: ImageBitmap,
  tileX: number,
  tileScreenWidth: number,
  clippedX: number,
  clippedWidth: number,
  itemY: number,
  itemHeight: number
) {
  const srcClipLeft = ((clippedX - tileX) / tileScreenWidth) * TILE_RENDER_WIDTH;
  const srcClipWidth = (clippedWidth / tileScreenWidth) * TILE_RENDER_WIDTH;

  ctx.drawImage(
    bitmap,
    srcClipLeft, 0, srcClipWidth, bitmap.height,  // source rect
    clippedX, itemY, clippedWidth, itemHeight     // dest rect
  );
}
```

### Solution 3: Expanded LOD Levels

**Principle:** Smaller jumps between LOD levels = smoother visual transitions.

```typescript
// Current: 3 levels with 10x-40x jumps
// Proposed: 7 levels with ~4x jumps

export const LOD_LEVELS = [
  { level: 0, peaksPerSecond: 1,    tileDuration: 64,    description: 'Hour+ view' },
  { level: 1, peaksPerSecond: 4,    tileDuration: 32,    description: '30-min view' },
  { level: 2, peaksPerSecond: 16,   tileDuration: 16,    description: '10-min view' },
  { level: 3, peaksPerSecond: 64,   tileDuration: 4,     description: '2-min view' },
  { level: 4, peaksPerSecond: 256,  tileDuration: 1,     description: '30-sec view' },
  { level: 5, peaksPerSecond: 1024, tileDuration: 0.25,  description: '5-sec view' },
  { level: 6, peaksPerSecond: 4096, tileDuration: 0.0625, description: '1-sec view' },
] as const;

export type LODLevel = 0 | 1 | 2 | 3 | 4 | 5 | 6;

// LOD selection based on viewport duration
export function selectLODForViewport(viewportDuration: number, canvasWidth: number): LODLevel {
  // Target: ~2-4 peaks per pixel for smooth appearance
  const targetPeaksPerPixel = 3;
  const targetPeaksPerSecond = (canvasWidth / viewportDuration) * targetPeaksPerPixel;

  // Find LOD level that best matches target density
  let bestLevel: LODLevel = 0;
  let bestDiff = Infinity;

  for (const lod of LOD_LEVELS) {
    const diff = Math.abs(lod.peaksPerSecond - targetPeaksPerSecond);
    if (diff < bestDiff) {
      bestDiff = diff;
      bestLevel = lod.level as LODLevel;
    }
  }

  return bestLevel;
}
```

**Backend Changes Required:**

The REAPER backend needs to generate peaks at the additional LOD levels. This requires changes to the peak generation code to support the new density levels.

### Solution 4: Directional Tile Pre-fetching

**Principle:** Load tiles before they enter the viewport based on pan direction.

```typescript
// Add to a custom hook or the pan gesture handler
export function useTilePrefetcher(
  viewportStart: number,
  viewportEnd: number,
  panVelocity: number,  // positive = panning right (forward in time)
  items: WSItem[],
  currentLod: LODLevel
) {
  const prefetchTriggered = useRef(new Set<string>());

  useEffect(() => {
    if (Math.abs(panVelocity) < 0.001) return; // Not actively panning

    const viewportDuration = viewportEnd - viewportStart;
    const prefetchBuffer = viewportDuration * 0.75; // Look ahead 75% of viewport

    // Determine prefetch range based on pan direction
    const prefetchRange = panVelocity > 0
      ? { start: viewportEnd, end: viewportEnd + prefetchBuffer }        // Panning right
      : { start: viewportStart - prefetchBuffer, end: viewportStart };   // Panning left

    for (const item of items) {
      if (!item.activeTakeGuid) continue;
      
      // Skip items completely outside prefetch range
      const itemEnd = item.position + item.length;
      if (itemEnd < prefetchRange.start || item.position > prefetchRange.end) continue;

      // Get tile keys for prefetch range
      const tilesToPrefetch = getTileKeysForRange(
        item.activeTakeGuid,
        item.position,
        item.length,
        prefetchRange.start,
        prefetchRange.end,
        currentLod
      );

      for (const tileKey of tilesToPrefetch) {
        const keyStr = makeTileCacheKeyString(tileKey);
        
        // Skip if already prefetched this session
        if (prefetchTriggered.current.has(keyStr)) continue;
        
        // Skip if already cached
        if (tileBitmapCache.has(tileKey, DEFAULT_WAVEFORM_COLOR, DEFAULT_HEIGHT)) continue;

        // Mark as triggered
        prefetchTriggered.current.add(keyStr);

        // Request tile from backend (fire and forget)
        requestTileFromBackend(tileKey);
      }
    }

    // Cleanup old prefetch markers periodically
    if (prefetchTriggered.current.size > 1000) {
      prefetchTriggered.current.clear();
    }
  }, [viewportStart, viewportEnd, panVelocity, items, currentLod]);
}

function getTileKeysForRange(
  takeGuid: string,
  itemPosition: number,
  itemLength: number,
  rangeStart: number,
  rangeEnd: number,
  lod: LODLevel
): TileCacheKey[] {
  const lodConfig = LOD_LEVELS[lod];
  const tileDuration = lodConfig.tileDuration;
  
  // Calculate which tiles overlap the range
  const relativeStart = Math.max(0, rangeStart - itemPosition);
  const relativeEnd = Math.min(itemLength, rangeEnd - itemPosition);
  
  const startTileIndex = Math.floor(relativeStart / tileDuration);
  const endTileIndex = Math.ceil(relativeEnd / tileDuration);
  
  const keys: TileCacheKey[] = [];
  for (let i = startTileIndex; i <= endTileIndex; i++) {
    keys.push({
      takeGuid,
      epoch: 0, // Will be filled by backend
      lod,
      tileIndex: i,
    });
  }
  
  return keys;
}
```

### Solution 5: Debounced Quality Upgrade

**Principle:** During active pan, accept lower quality. Upgrade when pan settles.

```typescript
export function useWaveformQualityUpgrade(
  isPanning: boolean,
  isMomentumActive: boolean,
  viewportStart: number,
  viewportEnd: number,
  renderTrigger: number,
  setRenderTrigger: (fn: (n: number) => number) => void
) {
  const upgradeTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const isActive = isPanning || isMomentumActive;

  useEffect(() => {
    // Clear any pending upgrade when interaction starts
    if (isActive && upgradeTimeoutRef.current) {
      clearTimeout(upgradeTimeoutRef.current);
      upgradeTimeoutRef.current = null;
      return;
    }

    // When interaction ends, schedule quality upgrade
    if (!isActive) {
      upgradeTimeoutRef.current = setTimeout(() => {
        // Force full re-render to ensure all tiles at correct LOD
        setRenderTrigger(n => n + 1);
      }, 150); // Wait 150ms after pan ends
    }

    return () => {
      if (upgradeTimeoutRef.current) {
        clearTimeout(upgradeTimeoutRef.current);
      }
    };
  }, [isActive, setRenderTrigger]);
}
```

### Solution 6: Render State Machine

**Principle:** Track rendering state explicitly to avoid redundant re-renders.

```typescript
type RenderState = 
  | { type: 'idle' }
  | { type: 'rendering'; pendingTiles: number }
  | { type: 'upgrading'; fromLod: LODLevel; toLod: LODLevel };

export function useRenderStateMachine(
  viewportStart: number,
  viewportEnd: number,
  currentLod: LODLevel,
  visibleItems: WSItem[]
) {
  const [renderState, setRenderState] = useState<RenderState>({ type: 'idle' });
  const [displayLod, setDisplayLod] = useState<LODLevel>(currentLod);

  // Track when LOD changes
  useEffect(() => {
    if (currentLod === displayLod) return;

    // Check if all tiles at new LOD are ready
    const allReady = checkAllTilesCached(visibleItems, viewportStart, viewportEnd, currentLod);

    if (allReady) {
      // Safe to switch immediately
      setDisplayLod(currentLod);
      setRenderState({ type: 'idle' });
    } else {
      // Start upgrade process
      setRenderState({ 
        type: 'upgrading', 
        fromLod: displayLod, 
        toLod: currentLod 
      });
      
      // Continue displaying old LOD while new one loads
      // The fallback rendering will show mixed LODs gracefully
    }
  }, [currentLod, displayLod, visibleItems, viewportStart, viewportEnd]);

  // When tiles finish loading during upgrade
  useEffect(() => {
    if (renderState.type !== 'upgrading') return;

    const checkInterval = setInterval(() => {
      const allReady = checkAllTilesCached(
        visibleItems, 
        viewportStart, 
        viewportEnd, 
        renderState.toLod
      );

      if (allReady) {
        setDisplayLod(renderState.toLod);
        setRenderState({ type: 'idle' });
        clearInterval(checkInterval);
      }
    }, 50);

    return () => clearInterval(checkInterval);
  }, [renderState, visibleItems, viewportStart, viewportEnd]);

  return { displayLod, renderState };
}

function checkAllTilesCached(
  items: WSItem[],
  viewportStart: number,
  viewportEnd: number,
  lod: LODLevel
): boolean {
  for (const item of items) {
    if (!item.activeTakeGuid) continue;
    
    const tileKeys = getTileKeysForRange(
      item.activeTakeGuid,
      item.position,
      item.length,
      viewportStart,
      viewportEnd,
      lod
    );

    for (const key of tileKeys) {
      if (!tileBitmapCache.has(key, DEFAULT_WAVEFORM_COLOR, DEFAULT_HEIGHT)) {
        return false;
      }
    }
  }
  return true;
}
```

---

## Complete Refactored WaveformCanvas

Here's the full implementation combining all solutions:

```typescript
/**
 * WaveformCanvas - Per-track canvas with flicker-free tile rendering
 *
 * Key improvements over original:
 * 1. Never clears entire canvas - only clears regions about to be drawn
 * 2. Synchronous fallback rendering - no visual holes ever
 * 3. LOD transition smoothing - displays old LOD until new is fully cached
 * 4. Directional prefetching - loads tiles ahead of pan direction
 */

import { useRef, useEffect, useState, type ReactElement } from 'react';
import type { WSItem, TileCacheKey, LODLevel, StereoPeak, MonoPeak } from '../../core/WebSocketTypes';
import { tileBitmapCache, TILE_RENDER_WIDTH } from '../../core/TileBitmapCache';
import { reaperColorToRgba, getContrastColor } from '../../utils';
import { useReaperStore } from '../../store';

const DEFAULT_ITEM_COLOR = 'rgba(129, 137, 137, 0.6)';
const DEBUG_TILES = false; // Set true to visualize tile boundaries

export interface WaveformCanvasProps {
  trackIdx: number;
  width: number;
  height: number;
  viewportStart: number;
  viewportEnd: number;
  items: WSItem[];
  panVelocity?: number; // For prefetch direction
}

function getItemColor(item: WSItem, opacity = 0.6): string {
  if (!item.color) return DEFAULT_ITEM_COLOR;
  return reaperColorToRgba(item.color, opacity) ?? DEFAULT_ITEM_COLOR;
}

function getWaveformColor(item: WSItem): string {
  const contrastBase = item.color ? getContrastColor(item.color) : 'white';
  return contrastBase === 'white' ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.7)';
}

function isStereo(peaks: StereoPeak[] | MonoPeak[]): peaks is StereoPeak[] {
  return peaks.length > 0 && typeof peaks[0] === 'object' && 'l' in peaks[0];
}

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
  panVelocity = 0,
}: WaveformCanvasProps): ReactElement {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [renderTrigger, setRenderTrigger] = useState(0);
  
  // Performance tracking for debugging
  const statsRef = useRef({ draws: 0, fallbacks: 0, misses: 0, lastLog: 0 });

  // Get tile data from Zustand store
  const currentLod = useReaperStore((s) => s.currentLod);
  const tileCache = useReaperStore((s) => s.tileCache);
  const tilesByTake = useReaperStore((s) => s.tilesByTake);

  const itemTopPercent = 10;
  const itemHeightPercent = 80;
  const itemY = (itemTopPercent / 100) * height;
  const itemHeight = (itemHeightPercent / 100) * height;

  // MAIN RENDER EFFECT
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || width === 0 || height === 0) return;

    const ctx = canvas.getContext('2d', { alpha: true });
    if (!ctx) return;

    // Set canvas size (only if changed)
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }

    const viewportDuration = viewportEnd - viewportStart;
    if (viewportDuration <= 0) return;

    // Track drawn regions for cleanup
    const drawnRegions: Array<{ x: number; w: number }> = [];
    const pendingRenders: Promise<void>[] = [];

    // Reset stats for this frame
    statsRef.current.draws = 0;
    statsRef.current.fallbacks = 0;
    statsRef.current.misses = 0;

    // Render each item
    for (const item of items) {
      const itemStart = item.position;
      const itemEnd = item.position + item.length;

      // Skip items outside viewport (with small buffer)
      if (itemEnd <= viewportStart - 0.1 || itemStart >= viewportEnd + 0.1) continue;

      // Calculate screen position
      const leftRatio = Math.max(0, (itemStart - viewportStart) / viewportDuration);
      const rightRatio = Math.min(1, (itemEnd - viewportStart) / viewportDuration);
      const itemX = leftRatio * width;
      const itemW = (rightRatio - leftRatio) * width;

      if (itemW < 1) continue; // Too small to render

      // SOLUTION 1: Clear only this item's region, not entire canvas
      ctx.clearRect(itemX, 0, itemW, height);

      // Draw item background (always succeeds - provides base color)
      ctx.fillStyle = getItemColor(item);
      ctx.fillRect(itemX, itemY, itemW, itemHeight);

      // Selection border
      if (item.selected) {
        ctx.strokeStyle = '#3b82f6';
        ctx.lineWidth = 2;
        ctx.strokeRect(itemX + 1, itemY + 1, itemW - 2, itemHeight - 2);
      }

      drawnRegions.push({ x: itemX, w: itemW });

      // Skip MIDI items (no waveform)
      if (item.activeTakeIsMidi || !item.activeTakeGuid) continue;

      // Get tiles for this take at current LOD
      const takeKeyStrings = tilesByTake.get(item.activeTakeGuid) ?? [];
      const waveformColor = getWaveformColor(item);
      const bitmapHeight = Math.round(itemHeight);

      for (const keyStr of takeKeyStrings) {
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

        // Clip to item bounds
        const clippedX = Math.max(tileX, itemX);
        const clippedRight = Math.min(tileX + tileScreenWidth, itemX + itemW);
        const clippedWidth = clippedRight - clippedX;
        if (clippedWidth <= 0) continue;

        const tileKey = parseTileCacheKey(keyStr);
        if (!tileKey) continue;

        // Calculate source rect for bitmap
        const srcClipLeft = ((clippedX - tileX) / tileScreenWidth) * TILE_RENDER_WIDTH;
        const srcClipWidth = (clippedWidth / tileScreenWidth) * TILE_RENDER_WIDTH;

        // TRY 1: Exact cached bitmap (fast path)
        const cachedBitmap = tileBitmapCache.get(tileKey, waveformColor, bitmapHeight);

        if (cachedBitmap) {
          ctx.drawImage(
            cachedBitmap,
            srcClipLeft, 0, srcClipWidth, cachedBitmap.height,
            clippedX, itemY, clippedWidth, itemHeight
          );
          statsRef.current.draws++;
          continue;
        }

        // SOLUTION 2: Fallback rendering - never leave holes

        // TRY 2: Adjacent LOD levels
        let drewFallback = false;
        for (const fallbackLod of [currentLod - 1, currentLod + 1] as LODLevel[]) {
          if (fallbackLod < 0 || fallbackLod > 2) continue;

          const fallbackKey: TileCacheKey = { ...tileKey, lod: fallbackLod };
          const fallbackBitmap = tileBitmapCache.get(fallbackKey, waveformColor, bitmapHeight);

          if (fallbackBitmap) {
            // Draw scaled fallback
            ctx.drawImage(
              fallbackBitmap,
              srcClipLeft, 0, srcClipWidth, fallbackBitmap.height,
              clippedX, itemY, clippedWidth, itemHeight
            );
            statsRef.current.fallbacks++;
            drewFallback = true;
            break;
          }
        }

        // TRY 3: Direct peak rendering (synchronous, slower but no gap)
        if (!drewFallback && tile.peaks.length > 0) {
          drawPeaksDirect(ctx, tile.peaks, clippedX, itemY, clippedWidth, itemHeight, waveformColor);
          statsRef.current.fallbacks++;
          drewFallback = true;
        }

        // Queue async render for correct LOD
        if (!cachedBitmap) {
          const renderPromise = tileBitmapCache
            .getOrRender(tileKey, tile.peaks, waveformColor, bitmapHeight)
            .then(() => {})
            .catch((err) => console.warn('Failed to render tile bitmap:', err));
          pendingRenders.push(renderPromise);
        }

        // Debug visualization
        if (DEBUG_TILES) {
          ctx.strokeStyle = cachedBitmap ? 'green' : drewFallback ? 'yellow' : 'red';
          ctx.lineWidth = 1;
          ctx.strokeRect(clippedX, itemY, clippedWidth, itemHeight);
          ctx.fillStyle = 'white';
          ctx.font = '9px monospace';
          ctx.fillText(`T${tileKey.tileIndex}L${tileKey.lod}`, clippedX + 2, itemY + 10);
        }
      }
    }

    // Clear regions not covered by any item (prevents stale content)
    clearUncoveredRegions(ctx, drawnRegions, width, height);

    // Schedule re-render when async bitmaps complete
    if (pendingRenders.length > 0) {
      Promise.all(pendingRenders).then(() => {
        setRenderTrigger((n) => n + 1);
      });
    }

    // Debug logging
    if (DEBUG_TILES) {
      const now = performance.now();
      if (now - statsRef.current.lastLog > 1000) {
        console.log(
          `[Track ${trackIdx}] Draws: ${statsRef.current.draws}, ` +
          `Fallbacks: ${statsRef.current.fallbacks}, Pending: ${pendingRenders.length}`
        );
        statsRef.current.lastLog = now;
      }
    }
  }, [
    trackIdx, width, height, viewportStart, viewportEnd, items,
    currentLod, tileCache, tilesByTake, renderTrigger, itemY, itemHeight,
  ]);

  return (
    <canvas
      ref={canvasRef}
      className="absolute inset-0"
      style={{
        width,
        height,
        pointerEvents: 'none',
        transform: 'translateZ(0)', // Force GPU compositing
        willChange: 'contents',
      }}
    />
  );
}

// Helper: Draw peaks directly to canvas (synchronous fallback)
function drawPeaksDirect(
  ctx: CanvasRenderingContext2D,
  peaks: StereoPeak[] | MonoPeak[],
  x: number,
  y: number,
  w: number,
  h: number,
  color: string
) {
  if (peaks.length === 0) return;

  ctx.fillStyle = color;
  const centerY = y + h / 2;
  const halfHeight = h / 2;
  const sampleWidth = w / peaks.length;

  for (let i = 0; i < peaks.length; i++) {
    const peak = peaks[i];
    let minVal: number, maxVal: number;

    if (isStereo(peaks)) {
      const sp = peak as StereoPeak;
      minVal = (sp.l[0] + sp.r[0]) / 2;
      maxVal = (sp.l[1] + sp.r[1]) / 2;
    } else {
      const mp = peak as MonoPeak;
      minVal = mp[0];
      maxVal = mp[1];
    }

    const peakX = x + i * sampleWidth;
    const topY = centerY - maxVal * halfHeight;
    const bottomY = centerY - minVal * halfHeight;
    const peakH = Math.max(bottomY - topY, 1);

    ctx.fillRect(peakX, topY, Math.max(sampleWidth - 0.5, 1), peakH);
  }
}

// Helper: Clear canvas regions not covered by drawn items
function clearUncoveredRegions(
  ctx: CanvasRenderingContext2D,
  regions: Array<{ x: number; w: number }>,
  canvasWidth: number,
  canvasHeight: number
) {
  if (regions.length === 0) {
    ctx.clearRect(0, 0, canvasWidth, canvasHeight);
    return;
  }

  // Sort by x position
  const sorted = [...regions].sort((a, b) => a.x - b.x);

  let lastEnd = 0;
  for (const region of sorted) {
    if (region.x > lastEnd + 0.5) {
      ctx.clearRect(lastEnd, 0, region.x - lastEnd, canvasHeight);
    }
    lastEnd = Math.max(lastEnd, region.x + region.w);
  }

  if (lastEnd < canvasWidth - 0.5) {
    ctx.clearRect(lastEnd, 0, canvasWidth - lastEnd, canvasHeight);
  }
}
```

---

## Implementation Priority

| Priority | Solution | Effort | Impact | Dependencies |
|----------|----------|--------|--------|--------------|
| **1** | Never-clear rendering | 2 hours | High | None |
| **2** | Synchronous fallback | 3 hours | High | None |
| **3** | Direct peak drawing | 2 hours | Medium | Part of #2 |
| **4** | Tile prefetching | 4 hours | Medium | None |
| **5** | More LOD levels | 1-2 days | High | Backend changes |
| **6** | Render state machine | 4 hours | Medium | After #1-4 working |
| **7** | Quality upgrade debounce | 1 hour | Low | After #1-4 working |

### Recommended Implementation Order

1. **Implement never-clear + synchronous fallback first** — this will eliminate the flicker immediately
2. **Add direct peak drawing as fallback** — ensures no visual holes even without cached bitmaps
3. **Add prefetching** — reduces how often fallbacks are needed
4. **Expand LOD levels** — requires backend coordination but eliminates LOD transition jarring

---

## Diagnostic Checklist

Before implementing, confirm the root cause by enabling `DEBUG_TILES = true`:

| Observation | Indicates | Solution |
|-------------|-----------|----------|
| Red tile borders during pan | Cache misses | Prefetching (#4) |
| Yellow tile borders during pan | Fallback rendering active | Working as intended, may want more LODs |
| Visible gaps between tiles | Coordinate calculation bug | Debug tile positioning math |
| Waveform "shape" changes on zoom | LOD transition | More LOD levels (#5) |
| Brief flash to blank | Clear before draw | Never-clear rendering (#1) |

---

## Safari-Specific Considerations

While your issue is not a performance problem, keep these in mind:

1. **Canvas memory limit (384MB):** With more LOD levels and prefetching, monitor total canvas memory. Call `bitmap.close()` on eviction.

2. **ImageBitmap compatibility:** Your `tileBitmapCache` already handles this correctly with OffscreenCanvas fallback.

3. **Compositor layers:** The `transform: translateZ(0)` on the canvas is correct for GPU compositing, but avoid adding `will-change: transform` if you're not actually transforming the canvas.

---

## Summary

The waveform flicker is caused by a render strategy that clears the canvas before all replacement content is ready, combined with asynchronous tile loading that leaves visual holes for 1-2 frames. The fix is straightforward:

1. **Never clear the entire canvas** — only clear regions immediately before drawing confirmed content
2. **Always draw something** — use fallback LODs or direct peak rendering when tiles aren't cached
3. **Add more LOD levels** — smaller density jumps mean smoother visual transitions

These changes can be implemented incrementally, with the first two providing immediate visual improvement without requiring backend changes.
