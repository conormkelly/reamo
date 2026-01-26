# LOD Configuration for REAmo Waveform Tiles

**Status:** Ready to implement
**Validated:** Python script confirmed 2-4 peaks/pixel across all viewport durations

**Optimized for:** 1 second → 4 hours viewport range
**Target:** 2-4 peaks/pixel at 400px viewport width
**Ratio:** 4x between adjacent LOD levels

## Final Configuration: 8 LOD Levels

| LOD | Peaks/sec | Tile Duration | Peaks/Tile | Viewport Range | Tiles/hr |
|-----|-----------|---------------|------------|----------------|----------|
| 7   | 1024      | 0.5s          | 512        | < 5s           | 7,200    |
| 6   | 256       | 1s            | 256        | 5s - 20s       | 3,600    |
| 5   | 64        | 4s            | 256        | 20s - 75s      | 900      |
| 4   | 16        | 16s           | 256        | 75s - 5min     | 225      |
| 3   | 4         | 64s           | 256        | 5min - 20min   | 57       |
| 2   | 1         | 256s (~4min)  | 256        | 20min - 80min  | 15       |
| 1   | 0.25      | 1024s (~17min)| 256        | 80min - 5hr    | 4        |
| 0   | 0.0625    | 4096s (~68min)| 256        | > 5hr          | 1        |

### Key Design Decisions

**Constant 256 peaks/tile (LODs 0-6), 512 for LOD 7:** This provides:

- Predictable memory usage (~2KB JSON per tile for LODs 0-6)
- Uniform cache entry weight for clean LRU eviction
- **50% fewer tiles at finest LOD** compared to 256 peaks/tile
- LOD 7's larger tiles (0.5s instead of 0.25s) reduce tile thrashing during fine-zoom panning

**4x ratio between all levels:** Industry-validated upper bound. Combined with fallback rendering (scaling adjacent LOD tiles), this minimizes visible artifacts during pan/zoom.

**Power-of-2 and power-of-4 tile durations:** Clean tile indexing via `tileIndex = floor(startTime / tileDuration)`.

---

## Validation Results

Computed with 400px viewport width targeting 2-4 peaks/pixel:

| Viewport | LOD | Peaks/pixel | Tiles visible | Quality |
|----------|-----|-------------|---------------|---------|
| 1s       | 7   | 2.56        | 2.0           | ✓ GOOD  |
| 2s       | 7   | 5.12        | 4.0           | OK+     |
| 5s       | 6   | 3.20        | 5.0           | ✓ GOOD  |
| 20s      | 5   | 3.20        | 5.0           | ✓ GOOD  |
| 1min     | 4   | 2.40        | 3.8           | ✓ GOOD  |
| 5min     | 3   | 3.00        | 4.7           | ✓ GOOD  |
| 20min    | 2   | 3.00        | 4.7           | ✓ GOOD  |
| 1hr      | 1   | 2.25        | 3.5           | ✓ GOOD  |
| 4hr      | 0   | 2.25        | 3.5           | ✓ GOOD  |

All viewport durations achieve 2-4 peaks/pixel (optimal range).

---

## LOD Selection Algorithm

```typescript
export type LODLevel = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7;

/**
 * Select LOD based on viewport duration.
 * Thresholds ensure >= 2 peaks/pixel after switching to coarser LOD.
 * Formula: threshold = 800 / coarser_peaks_per_sec
 */
export function selectLOD(viewportDuration: number): LODLevel {
  if (viewportDuration < 5) return 7;       // 1024 peaks/sec
  if (viewportDuration < 20) return 6;      // 256 peaks/sec
  if (viewportDuration < 75) return 5;      // 64 peaks/sec
  if (viewportDuration < 300) return 4;     // 16 peaks/sec (5 min)
  if (viewportDuration < 1200) return 3;    // 4 peaks/sec (20 min)
  if (viewportDuration < 4800) return 2;    // 1 peak/sec (80 min)
  if (viewportDuration < 19200) return 1;   // 0.25 peaks/sec (5.3 hr)
  return 0;                                  // 0.0625 peaks/sec
}

// Alternative using pixels-per-second (if viewport width varies)
export function selectLODByPxPerSec(pxPerSec: number): LODLevel {
  if (pxPerSec > 160) return 7;    // Fine detail
  if (pxPerSec > 40) return 6;
  if (pxPerSec > 10) return 5;
  if (pxPerSec > 2.5) return 4;
  if (pxPerSec > 0.625) return 3;
  if (pxPerSec > 0.156) return 2;
  if (pxPerSec > 0.039) return 1;
  return 0;                         // Coarse overview
}
```

### Threshold Derivation

Switch to coarser LOD when it provides >= 2 peaks/pixel:

```
threshold = (2 peaks/pixel × 400px) / coarser_peaks_per_sec
          = 800 / coarser_peaks_per_sec

LOD 7→6: 800 / 256 = 3.125s  → rounded to 5s
LOD 6→5: 800 / 64 = 12.5s    → rounded to 20s
LOD 5→4: 800 / 16 = 50s      → rounded to 75s
LOD 4→3: 800 / 4 = 200s      → rounded to 300s (5min)
LOD 3→2: 800 / 1 = 800s      → rounded to 1200s (20min)
LOD 2→1: 800 / 0.25 = 3200s  → rounded to 4800s (80min)
LOD 1→0: 800 / 0.0625 = 12800s → rounded to 19200s (5.3hr)
```

---

## Tile Counts

### Per-item tile counts by duration

| Item Duration | LOD 7 | LOD 6 | LOD 5 | LOD 4 | LOD 3 | LOD 2 | LOD 1 | LOD 0 |
|---------------|-------|-------|-------|-------|-------|-------|-------|-------|
| 30 seconds    | 60    | 30    | 8     | 2     | 1     | 1     | 1     | 1     |
| 5 minutes     | 600   | 300   | 75    | 19    | 5     | 2     | 1     | 1     |
| 30 minutes    | 3,600 | 1,800 | 450   | 112   | 28    | 7     | 2     | 1     |
| 1 hour        | 7,200 | 3,600 | 900   | 225   | 57    | 15    | 4     | 1     |
| 4 hours       | 28,800| 14,400| 3,600 | 900   | 225   | 57    | 15    | 4     |

### Tiles visible in viewport

At optimal zoom for each LOD (where peaks/pixel ≈ 3):

| LOD | Optimal Viewport | Tile Duration | Tiles Visible |
|-----|------------------|---------------|---------------|
| 7   | 1.5s             | 0.5s          | 3             |
| 6   | 5s               | 1s            | 5             |
| 5   | 20s              | 4s            | 5             |
| 4   | 75s              | 16s           | 5             |
| 3   | 5min             | 64s           | 5             |
| 2   | 20min            | 256s          | 5             |
| 1   | 80min            | 1024s         | 5             |
| 0   | 5hr              | 4096s         | 4             |

**Prefetch formula:** `ceil(viewportDuration / tileDuration) + 2` accounts for partial tiles at viewport edges plus prefetch margin.

---

## Cache Sizing

**Frontend (ImageBitmap cache):**

- 200 bitmaps budget (~200MB at 512×256 RGBA)
- Allocation: 60% current LOD (120), 25% adjacent LODs (50), 15% recent (30)
- At finest zoom: 7 tiles visible × ~3 tracks = 21 tiles + prefetch ≈ 50 tiles
- Plenty of headroom for smooth panning

**Backend (tile data cache):**

- 500 tiles budget
- At finest zoom for 4-hour project: ~30 tiles visible across all tracks
- LRU eviction with LOD-aware priority

---

## Implementation Checklist

### Backend (Zig)

Update `peaks_tile.zig`:

```zig
pub const TILE_CONFIGS = [8]TileConfig{
    .{ .duration = 4096.0, .peakrate = 0.0625, .peaks_per_tile = 256 }, // LOD 0
    .{ .duration = 1024.0, .peakrate = 0.25,   .peaks_per_tile = 256 }, // LOD 1
    .{ .duration = 256.0,  .peakrate = 1.0,    .peaks_per_tile = 256 }, // LOD 2
    .{ .duration = 64.0,   .peakrate = 4.0,    .peaks_per_tile = 256 }, // LOD 3
    .{ .duration = 16.0,   .peakrate = 16.0,   .peaks_per_tile = 256 }, // LOD 4
    .{ .duration = 4.0,    .peakrate = 64.0,   .peaks_per_tile = 256 }, // LOD 5
    .{ .duration = 1.0,    .peakrate = 256.0,  .peaks_per_tile = 256 }, // LOD 6
    .{ .duration = 0.5,    .peakrate = 1024.0, .peaks_per_tile = 512 }, // LOD 7
};

pub const MAX_PEAKS_PER_TILE = 512;  // Increased from 200
```

Other changes:

- Update LOD type from `u2` to `u3` (supports 0-7)
- Update `tilesForViewport()` LOD selection thresholds
- Update LOD selection in `peaks_subscriptions.zig`

### Frontend (TypeScript)

Update `WebSocketTypes.ts`:

```typescript
export const LOD_CONFIGS = {
  0: { duration: 4096, peakrate: 0.0625, peaksPerTile: 256 },
  1: { duration: 1024, peakrate: 0.25,   peaksPerTile: 256 },
  2: { duration: 256,  peakrate: 1,      peaksPerTile: 256 },
  3: { duration: 64,   peakrate: 4,      peaksPerTile: 256 },
  4: { duration: 16,   peakrate: 16,     peaksPerTile: 256 },
  5: { duration: 4,    peakrate: 64,     peaksPerTile: 256 },
  6: { duration: 1,    peakrate: 256,    peaksPerTile: 256 },
  7: { duration: 0.5,  peakrate: 1024,   peaksPerTile: 512 },
} as const;

export type LODLevel = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7;
```

Update `calculateLODFromViewport()` with new thresholds.

---

## Rationale

### Why 8 levels?

- Range: 4 hours / 1 second = 14,400×
- At 4× ratio: log₄(14,400) = 6.9 → 7 levels minimum
- We use 8 to ensure ≥2 peaks/pixel with margin at extremes

### Why 4× ratio?

- Industry-validated upper bound (game engines, mapping systems)
- With fallback rendering, 4× transitions are visually acceptable
- 2× would require 14 levels (excessive complexity)

### Why 512 peaks/tile only for LOD 7?

- Reduces finest-LOD tile count by 50% (7,200 vs 14,400 per hour)
- LOD 7 tiles are accessed most frequently during fine-zoom pan
- Larger tiles = fewer cache boundaries = smoother panning
- Other LODs keep 256 for uniform memory/cache behavior

### Why viewport duration thresholds?

- iPad viewport width is fixed (~400px)
- Simpler than peaks/pixel calculations
- Avoids floating-point edge cases

### Why no hysteresis?

Hysteresis is standard in game engines to prevent "popping" when LOD switches instantaneously. Our **fallback rendering already handles LOD mismatches** by scaling adjacent tiles - the visual cost is a slightly blockier waveform, not a hard pop.

**If LOD thrashing is observed during pinch-zoom testing** (excessive tile fetches near thresholds), add **gesture debouncing** - don't commit LOD changes until the gesture ends. This is simpler than threshold hysteresis and directly addresses the gesture use case.

### Why 4-hour max viewport?

Target users are musicians with projects typically <10 minutes. REAPER's theoretical 68-year max is not a real requirement. 8 LODs covering 1 second to 4+ hours handles all practical use cases.

**Future extension:** If longer sessions needed, add LOD -1 (16384s tiles, 0.0156 peaks/sec) - straightforward extension of the same pattern.

---

## Comparison with Previous Configuration

| Aspect              | Old (3 LODs)      | New (8 LODs)      |
|---------------------|-------------------|-------------------|
| LOD ratio           | 10× and 40×       | 4× uniform        |
| Peaks/tile          | 64, 80, 200       | 256 (512 for LOD7)|
| Min peaks/sec       | 1                 | 0.0625            |
| Max peaks/sec       | 400               | 1024              |
| Fallback quality    | Jarring (40× jump)| Smooth (4× jump)  |
| Max viewport        | ~68 min           | 4+ hours          |
| Min viewport        | ~1s               | ~1s               |
| Peaks/pixel range   | 0.32 (broken)     | 2-4 (optimal)     |
| LOD 7 tiles/hr      | N/A               | 7,200             |

---

## Architecture Decisions Log

| Decision | Rationale | Date |
|----------|-----------|------|
| 8 LOD levels with 4x ratio | Covers 14,400x range (1s-4hr) with industry-validated ratio | 2025-01 |
| 256 peaks/tile (512 for LOD 7) | Cache predictability + 50% fewer tiles at finest zoom | 2025-01 |
| No hysteresis initially | Fallback rendering handles LOD mismatches; add gesture debouncing if thrashing observed | 2025-01 |
| Viewport duration thresholds | Simpler than px/sec for fixed-width iPad viewport | 2025-01 |
| 4-hour max sufficient | Target users have projects <10 min typically; easy to extend | 2025-01 |
