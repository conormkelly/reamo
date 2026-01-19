# REAmo Adaptive Waveform Zoom Architecture

## Problem Statement

REAmo's timeline shows waveform "blobs" for audio items. The current implementation uses **fixed 30 peaks per item regardless of zoom level**, causing waveforms to become useless at precision zoom levels.

### Success Criteria

| Criterion | Target |
|-----------|--------|
| Waveforms useful at 1s zoom | See individual transients |
| No perceptible lag on zoom | < 300ms settle time |
| Pan is instant | 0ms from cache |
| REAPER stays responsive | No frame drops |
| Cache is effective | > 80% hit rate |

---

## Critical Discovery: ARM64 macOS GetFunc() Bug

**`GetMediaItemTake_Peaks` obtained via `GetFunc()` fails with tile-slicing parameters on ARM64 macOS.**

See [PEAK_GENERATION.md](PEAK_GENERATION.md) for full analysis. Summary:

| Parameters | Lua Result | Zig/C via GetFunc() |
|------------|------------|---------------------|
| Low peakrate (0.02), no offset | WORKS | WORKS |
| High peakrate (400), no offset | WORKS | **FAILS (0 peaks)** |
| High peakrate (400) + offset | WORKS | **FAILS (0 peaks)** |

**Root cause**: Apple's ARM64 ABI has non-standard parameter alignment. When function pointers are cast via GetFunc(), large float values (400.0) get misrouted.

**Implication**: We cannot use `GetMediaItemTake_Peaks` for tile-based fetching. Must use alternative approaches.

---

## Architecture: Hybrid LOD System

### LOD Levels

| LOD | Resolution | Tile Duration | Peaks/Tile | Source | Use Case |
|-----|------------|---------------|------------|--------|----------|
| 0 | 1 peak/sec | Full item | varies | GetMediaItemTake_Peaks | Overview |
| 1 | 10 peaks/sec | Full item | varies | GetMediaItemTake_Peaks | Normal editing |
| 2 | 400 peaks/sec | 0.5s tiles | 200 | **AudioAccessor** | Precision editing |

### Why This Split?

- **LOD 0/1**: Low peakrate works via GetFunc(). Full-item fetch is simple and efficient.
- **LOD 2**: Requires AudioAccessor because high peakrate fails via GetFunc().

### LOD Selection

```typescript
function selectLOD(viewportDuration: number, viewportPixels: number): number {
  const pixelsPerSecond = viewportPixels / viewportDuration;

  if (pixelsPerSecond > 200) return 2;   // Fine: 400 peaks/sec (AudioAccessor)
  if (pixelsPerSecond > 5) return 1;     // Medium: 10 peaks/sec
  return 0;                               // Coarse: 1 peak/sec
}
```

---

## LOD 0/1: Full-Item via GetMediaItemTake_Peaks

Uses the **working** code path (low peakrate, starttime = item position).

```zig
fn generatePeaksForItem(take, length, num_peaks, item_peaks) bool {
    const peakrate = num_peaks / length;  // e.g., 300/30s = 10 peaks/sec
    const starttime = item_peaks.position; // Exact item position - WORKS!

    const result = api.getMediaItemTakePeaks(
        take, peakrate, starttime, channels, num_peaks, buf
    );
    // This works because peakrate is low and no time offset
}
```

### Caching for LOD 0/1

```
Key: (take_guid, lod_level, epoch)
Value: Full item peaks array
```

- One entry per item per LOD
- Memory: ~30KB per hour at LOD 1, ~3KB at LOD 0

---

## LOD 2: Tile-Based via AudioAccessor

Since GetMediaItemTake_Peaks fails with tile parameters, use AudioAccessor to read raw samples and compute peaks.

### Why AudioAccessor Works

- Different API surface, cleaner function signature
- SWS Extension uses this approach (battle-tested)
- No casting issues on ARM64

### Implementation

```zig
fn generateTileViaAccessor(
    allocator: Allocator,
    api: anytype,
    take: *anyopaque,
    tile_start_time: f64,  // Relative to item start
    tile_duration: f64,    // 0.5s for LOD 2
    num_peaks: usize,      // 200 for LOD 2
) ?CachedTile {
    // Create accessor (reuse if possible)
    const accessor = api.makeTakeAccessor(take) orelse return null;
    defer api.destroyTakeAccessor(accessor);

    // Use lower sample rate for efficiency (4000 Hz instead of 44100)
    const sample_rate: c_int = 4000;
    const samples_needed = @intFromFloat(tile_duration * @as(f64, sample_rate));
    const samples_per_peak = samples_needed / num_peaks;

    // Allocate sample buffer
    var sample_buf = allocator.alloc(f64, samples_needed * 2) catch return null;
    defer allocator.free(sample_buf);

    // Read samples
    const rv = api.readAccessorSamples(
        accessor,
        sample_rate,
        2,  // stereo
        tile_start_time,
        @intCast(samples_needed),
        sample_buf,
    );

    if (rv == 0) return null;

    // Compute peaks from samples
    var tile = CachedTile.empty();
    for (0..num_peaks) |p| {
        const start = p * samples_per_peak;
        const end = @min(start + samples_per_peak, samples_needed);

        var min_l: f64 = 1.0;
        var max_l: f64 = -1.0;
        var min_r: f64 = 1.0;
        var max_r: f64 = -1.0;

        for (start..end) |s| {
            const l = sample_buf[s * 2];
            const r = sample_buf[s * 2 + 1];
            min_l = @min(min_l, l);
            max_l = @max(max_l, l);
            min_r = @min(min_r, r);
            max_r = @max(max_r, r);
        }

        tile.peak_min[p * 2] = min_l;
        tile.peak_min[p * 2 + 1] = min_r;
        tile.peak_max[p * 2] = max_l;
        tile.peak_max[p * 2 + 1] = max_r;
    }

    tile.num_peaks = @intCast(num_peaks);
    tile.channels = detectMonoStereo(&tile, num_peaks);

    return tile;
}
```

### Performance: 4000 Hz vs 44100 Hz

For a 0.5s tile at 200 peaks:

| Sample Rate | Samples | Samples/Peak | CPU Work |
|-------------|---------|--------------|----------|
| 44100 Hz | 22050 | 110 | High |
| 4000 Hz | 2000 | 10 | **Low** |

4000 Hz is sufficient for peak detection and 11x faster.

### Caching for LOD 2

```
Key: (take_guid, lod_level=2, tile_index, epoch)
Value: CachedTile { peak_min[400], peak_max[400], num_peaks, channels }
```

- 0.5s tiles, 200 peaks each
- LRU eviction (500 entry limit)
- Enables pan/zoom cache reuse

---

## Cache Invalidation

### Epoch-Based (existing infrastructure)

```zig
fn computeEpoch(api, take) u32 {
    const source = api.getTakeSource(take);
    // Hash of source pointer + channel count
    // Changes when audio is replaced or re-rendered
    return hash(source_ptr, channels);
}
```

When epoch changes → all cached data for that take is stale.

### Track Structure Change Detection

```zig
fn computeTrackItemsHash(api, track) u64 {
    // Hash of all items: GUID, position, length, playrate, start_offset, active take
    // Changes when items are moved, trimmed, stretched, or take-swapped
}
```

When hash changes → re-fetch affected items.

### Invalidation Triggers

| Event | Action |
|-------|--------|
| Source audio edited | Epoch changes → cache miss |
| Item moved/trimmed/stretched | Track hash changes → re-fetch |
| Take switched | Different take_guid → different cache entry |
| LRU eviction | Old tiles dropped naturally |

---

## Request Flow

```
Client subscribes with viewport { start, end, width_px }
                ↓
viewportPeakrate() → selects LOD (1, 10, or 400 peaks/sec)
                ↓
┌─────────────────────────────────────────┐
│ LOD 0/1: Full-item path                 │
│   - Check cache by (guid, lod, epoch)   │
│   - If miss: GetMediaItemTake_Peaks     │
│   - Return peaks for viewport slice     │
├─────────────────────────────────────────┤
│ LOD 2: Tile path                        │
│   - Calculate tile range for viewport   │
│   - For each tile:                      │
│     - Check tile cache                  │
│     - If miss: AudioAccessor → compute  │
│   - Stitch tiles → return               │
└─────────────────────────────────────────┘
```

---

## Gesture Handling

### Timing Parameters

| Gesture | Strategy | Timing |
|---------|----------|--------|
| Pinch-to-zoom | Debounce | 200ms after end |
| Pan/scroll | Throttle | 100ms during |

### Buffer Prefetching

```typescript
const BUFFER_RATIO = 0.5;  // 50% viewport each side

function getTilesToFetch(viewport, lod) {
  const bufferedStart = viewport.start - (viewport.duration * BUFFER_RATIO);
  const bufferedEnd = viewport.end + (viewport.duration * BUFFER_RATIO);
  // ... calculate tile indices
}
```

---

## Memory Budget

### Per-Item (LOD 0/1)

- LOD 0: ~8 bytes/sec (1 peak × 2 channels × 4 bytes min/max)
- LOD 1: ~80 bytes/sec

### Per-Tile (LOD 2)

- 200 peaks × 2 channels × 8 bytes × 2 (min/max) = ~6.4 KB per tile
- 500 tile cache limit = ~3.2 MB max

### Total Target

< 5 MB for peaks across all cached data.

---

## Files to Modify

| File | Change |
|------|--------|
| `extension/src/peaks_generator.zig` | Add `generateTileViaAccessor()`, keep working full-item path |
| `extension/src/peaks_tile.zig` | Already has tile cache infrastructure |
| `extension/src/main.zig` | Route LOD 2 to AudioAccessor path |
| `extension/src/peaks_subscriptions.zig` | Already has viewport support |

---

## Reusable Code from Broken Tile Path

The following can be kept from `generateTileForTake`:

- **Tile boundary calculations** (clamping to item bounds)
- **Mono/stereo detection** (comparing L/R peaks)
- **TileInfo struct** (JSON serialization format)
- **generateTilesForSubscription orchestration** (viewport-to-tiles logic)

Replace only the API call with AudioAccessor approach.

---

## Summary

| LOD | Source | Why |
|-----|--------|-----|
| 0 (1/sec) | GetMediaItemTake_Peaks | Low peakrate works via GetFunc() |
| 1 (10/sec) | GetMediaItemTake_Peaks | Low peakrate works via GetFunc() |
| 2 (400/sec) | **AudioAccessor** | High peakrate fails via GetFunc() on ARM64 |

This hybrid approach:
1. Uses working code paths where possible
2. Falls back to AudioAccessor only when necessary (LOD 2)
3. Maintains tile-based caching for efficient pan/zoom
4. Keeps memory bounded with LRU eviction
