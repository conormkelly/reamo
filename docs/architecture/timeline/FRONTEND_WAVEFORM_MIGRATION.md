# Frontend Waveform Migration Plan: Tile-Based LOD + Canvas Architecture

## Summary

Migrate frontend from broken item-based peaks format to new tile-based LOD system, with full canvas architecture rewrite for 60fps performance on iPad Safari.

**Current State:** Backend sends tiles, frontend expects items → waveforms don't work
**Target State:** Tile-aware types, tile cache, layered canvas rendering

---

## Phase 1: Types & Event Handler (Get Waveforms Displaying)

**Goal:** Parse new tile format, store tiles, assemble for rendering
**Complexity:** M | **Time:** 2-3 hours | **Shippable:** YES

### 1.1 Add Tile Types (`frontend/src/core/WebSocketTypes.ts`)

```typescript
// NEW - tile-based format from backend
export interface PeaksTile {
  takeGuid: string;
  epoch: number;           // Cache invalidation signal
  lod: 0 | 1 | 2;         // LOD level
  tileIndex: number;       // Position within item
  itemPosition: number;    // Item start in project time
  startTime: number;       // Tile start (relative to item)
  endTime: number;         // Tile end (relative to item)
  channels: 1 | 2;
  peaks: StereoPeak[] | MonoPeak[];
}

export interface PeaksEventPayload {
  tiles: PeaksTile[];  // Flat array of tiles
}

export interface TileCacheKey {
  takeGuid: string;
  epoch: number;
  lod: 0 | 1 | 2;
  tileIndex: number;
}
```

**Also add:** LOD config constants matching backend `peaks_tile.zig`:

```typescript
export const LOD_CONFIGS = {
  0: { duration: 64, peakrate: 1, peaksPerTile: 64 },    // Coarse
  1: { duration: 8, peakrate: 10, peaksPerTile: 80 },   // Medium
  2: { duration: 0.5, peakrate: 400, peaksPerTile: 200 } // Fine
} as const;
```

### 1.2 Update State Slice (`frontend/src/store/slices/peaksSlice.ts`)

**Replace** `peaksByTrack: Map<trackIdx, Map<itemGuid, WSItemPeaks>>` with:

```typescript
interface PeaksSlice {
  // Subscription state (keep existing)
  peaksSubscriptionMode: PeaksSubscriptionMode;
  peaksSubscribedRange: { start: number; end: number } | null;
  peaksSubscribedGuids: string[] | null;

  // NEW: Current LOD level
  currentLod: 0 | 1 | 2;

  // NEW: Tile index by take (for lookup)
  tilesByTake: Map<string, TileCacheKey[]>;

  // NEW: Actions
  handlePeaksEvent: (payload: PeaksEventPayload) => void;
  setCurrentLod: (lod: 0 | 1 | 2) => void;

  // NEW: Selectors
  getTilesForTake: (takeGuid: string, lod: number) => CachedTile[];
  assemblePeaksForViewport: (
    takeGuid: string,
    itemPosition: number,
    itemLength: number,
    viewportStart: number,
    viewportEnd: number
  ) => StereoPeak[] | MonoPeak[] | null;
}
```

### 1.3 Update Event Handler (`frontend/src/store/index.ts`)

Update `handleWebSocketMessage` to parse new tile format:

- Call `handlePeaksEvent` with new payload structure
- Tiles stored in cache, indexed by take GUID

### 1.4 Files to Modify

| File | Changes |
|------|---------|
| `frontend/src/core/WebSocketTypes.ts` | Add `PeaksTile`, `TileCacheKey`, `LOD_CONFIGS`, update `PeaksEventPayload` |
| `frontend/src/store/slices/peaksSlice.ts` | Rewrite state structure, add tile handlers |
| `frontend/src/store/index.ts` | Update `isPeaksEvent` handler |

---

## Phase 2: Tile Cache Layer

**Goal:** Efficient LRU cache with proper invalidation
**Complexity:** M | **Time:** 3-4 hours | **Shippable:** YES

### 2.1 Create Tile Cache (`frontend/src/core/TileCache.ts`)

```typescript
const MAX_CACHE_SIZE = 500; // Match backend

class TileCacheImpl {
  private cache = new Map<string, CachedTile>();

  // Key format: `${takeGuid}:${epoch}:${lod}:${tileIndex}`
  get(key: TileCacheKey): CachedTile | undefined;
  set(key: TileCacheKey, tile: CachedTile): void;

  // Invalidate all tiles for a take when epoch changes
  invalidateTake(takeGuid: string): void;

  // Get tiles that cover a viewport range
  getTilesForViewport(
    takeGuid: string,
    lod: number,
    startTime: number,
    endTime: number
  ): CachedTile[];
}

export const tileCache = new TileCacheImpl();
```

### 2.2 Deprecate Old Cache

- Mark `frontend/src/core/PeaksCache.ts` as deprecated
- Keep for backward compat with `item/getPeaks` on-demand fetches

### 2.3 Files to Create/Modify

| File | Changes |
|------|---------|
| `frontend/src/core/TileCache.ts` | NEW - LRU tile cache |
| `frontend/src/core/PeaksCache.ts` | Add deprecation notice |
| `frontend/src/store/slices/peaksSlice.ts` | Use TileCache for storage |

---

## Phase 3: Canvas Architecture Rewrite

**Goal:** Layered canvas with tile-based rendering, 60fps on iPad
**Complexity:** L | **Time:** 6-8 hours | **Shippable:** YES

### 3.1 Target Architecture

```
┌─────────────────────────────────────────────────┐
│  Layer 4: DOM Playhead (CSS transform, 60fps)   │ ← Already done
├─────────────────────────────────────────────────┤
│  Layer 3: Selection Overlay Canvas              │ ← Future
├─────────────────────────────────────────────────┤
│  Layer 2: Waveform Canvas (1 per track lane)    │ ← THIS PHASE
│    - Viewport-sized (not item-sized)            │
│    - 1x DPR (saves 4x memory)                   │
│    - Tile-based ImageBitmap blitting            │
├─────────────────────────────────────────────────┤
│  Layer 1: Grid + Regions Canvas                 │ ← Currently DOM
└─────────────────────────────────────────────────┘
```

### 3.2 Create ImageBitmap Cache (`frontend/src/core/TileBitmapCache.ts`)

```typescript
const TILE_RENDER_WIDTH = 512; // Fixed pixels per tile

class TileBitmapCache {
  private cache = new Map<string, ImageBitmap>();
  private maxSize = 200; // ~50MB

  // Render peaks to ImageBitmap (async, uses OffscreenCanvas)
  async renderAndCache(
    key: TileCacheKey,
    peaks: StereoPeak[] | MonoPeak[],
    color: string
  ): Promise<ImageBitmap>;

  // Get cached bitmap for fast blitting
  get(key: TileCacheKey): ImageBitmap | null;

  // Free GPU memory on eviction
  evict(key: string): void;
}

export const tileBitmapCache = new TileBitmapCache();
```

### 3.3 Create Waveform Components

**`WaveformCanvas.tsx`** - Per-track canvas that renders all items:

```tsx
interface WaveformCanvasProps {
  trackIdx: number;
  width: number;
  height: number;
  viewportStart: number;
  viewportEnd: number;
  items: WSItem[];
  isGesturing: boolean;
}
```

Key features:

- Canvas sized to viewport (NOT item width)
- No DPR scaling for waveforms (1x)
- Blits cached ImageBitmaps for tiles
- Skips rendering during `isGesturing`
- Uses CSS `transform: translateZ(0)` for GPU compositing

**`WaveformLayer.tsx`** - Container for all track canvases:

```tsx
interface WaveformLayerProps {
  tracks: SkeletonTrack[];
  trackIndices: number[];
  items: WSItem[];
  viewportStart: number;
  viewportEnd: number;
  width: number;
  height: number;
  isGesturing: boolean;
}
```

### 3.4 Update MultiTrackLanes

Replace `LaneWaveform` component with `WaveformLayer`:

```tsx
// OLD (per-item canvas)
<LaneWaveform peaks={itemPeaks.peaks} widthPx={itemWidth} ... />

// NEW (track-level canvas with tile blitting)
<WaveformLayer
  tracks={tracks}
  items={visibleItems}
  viewportStart={viewport.visibleRange.start}
  viewportEnd={viewport.visibleRange.end}
  width={containerWidth}
  height={height}
  isGesturing={isGesturing}
/>
```

### 3.5 Files to Create/Modify

| File | Changes |
|------|---------|
| `frontend/src/core/TileBitmapCache.ts` | NEW - ImageBitmap LRU cache |
| `frontend/src/components/Timeline/WaveformCanvas.tsx` | NEW - Per-track canvas |
| `frontend/src/components/Timeline/WaveformLayer.tsx` | NEW - Container component |
| `frontend/src/components/Timeline/MultiTrackLanes.tsx` | Remove `LaneWaveform`, use `WaveformLayer` |
| `frontend/src/components/Timeline/index.ts` | Export new components |

---

## Phase 4: Prefetch & LOD Transitions

**Goal:** Seamless zoom experience with predictive loading
**Complexity:** M | **Time:** 3-4 hours | **Shippable:** YES

### 4.1 Prefetch Logic (`usePeaksSubscription.ts`)

- Request tiles for buffer zone (10s each side of viewport)
- Request next LOD level when approaching threshold
- Track pending requests to avoid duplicates

### 4.2 LOD Transition Handling (`WaveformCanvas.tsx`)

- Fall back to lower LOD while higher LOD loads
- Optional: Crossfade animation between LOD levels

### 4.3 Files to Modify

| File | Changes |
|------|---------|
| `frontend/src/hooks/usePeaksSubscription.ts` | Add prefetch logic, LOD prediction |
| `frontend/src/components/Timeline/WaveformCanvas.tsx` | LOD fallback rendering |
| `frontend/src/core/TileCache.ts` | Add `prefetchTiles()` method |

---

## Memory Budget

| Component | Count | Memory |
|-----------|-------|--------|
| Track canvases (8 lanes, 1x DPR) | 8 | ~4MB |
| Tile data cache (500 tiles) | 500 | ~3MB |
| ImageBitmap cache (200 tiles) | 200 | ~25MB |
| **Total** | | **~32MB** |

vs Current: 72MB+ for per-item canvases → **50%+ reduction**

---

## Critical iPad Safari Constraints

- 16MP per-canvas limit (4096×4096 physical pixels)
- ~384MB total canvas memory budget
- Use 1x DPR for waveforms (4x memory savings)
- Always call `bitmap.close()` on eviction
- Test `OffscreenCanvas` support (Safari 17+)

---

## Testing Strategy

| Phase | Tests |
|-------|-------|
| 1 | Unit: tile type parsing, assembly logic |
| 2 | Unit: cache LRU eviction, invalidation |
| 3 | Visual: Playwright regression, FPS during pan/pinch |
| 4 | Integration: prefetch coverage, LOD transitions |

---

## File Summary

### New Files

- `frontend/src/core/TileCache.ts`
- `frontend/src/core/TileBitmapCache.ts`
- `frontend/src/components/Timeline/WaveformCanvas.tsx`
- `frontend/src/components/Timeline/WaveformLayer.tsx`

### Modified Files

- `frontend/src/core/WebSocketTypes.ts`
- `frontend/src/store/slices/peaksSlice.ts`
- `frontend/src/store/index.ts`
- `frontend/src/hooks/usePeaksSubscription.ts`
- `frontend/src/components/Timeline/MultiTrackLanes.tsx`
- `frontend/src/components/Timeline/index.ts`

### Reference Files (read-only)

- `extension/API.md` (lines 781-903) - Tile format spec
- `extension/src/peaks_tile.zig` - Backend LOD configs
- `research/TIMELINE_CANVAS_ARCHITECTURE.md` - Architecture guidance
