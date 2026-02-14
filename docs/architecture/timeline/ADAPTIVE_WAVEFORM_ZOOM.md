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

## Architecture: Tile-Based LOD System via AudioAccessor

**Update (Jan 2026)**: Testing revealed that `GetMediaItemTake_Peaks` via `GetFunc()` fails for ALL peakrates on ARM64 macOS, not just high peakrates. Even low peakrate (0.02) returns 0 peaks when called through the extension. We now use `AudioAccessor` for all LOD levels.

### LOD Levels

| LOD | Resolution | Tile Duration | Peaks/Tile | Source | Use Case |
|-----|------------|---------------|------------|--------|----------|
| 0 | 1 peak/sec | 64s | 64 | AudioAccessor | Overview (zoomed out) |
| 1 | 10 peaks/sec | 8s | 80 | AudioAccessor | Normal editing |
| 2 | 400 peaks/sec | 0.5s | 200 | AudioAccessor | Precision editing |

### Why AudioAccessor for Everything?

- `GetMediaItemTake_Peaks` via `GetFunc()` is completely broken on ARM64 macOS
- `AudioAccessor` (via `GetAudioAccessorSamples`) works reliably
- Tile-based approach enables efficient caching across all zoom levels
- Unified code path is simpler to maintain

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

## Tile Generation via AudioAccessor

All LOD levels use the same tile-based approach with AudioAccessor.

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

### Tile Caching

```
Key: (take_guid, lod_level, tile_index, epoch)
Value: CachedTile { peak_min[400], peak_max[400], num_peaks, channels }
```

- LRU eviction (500 entry limit)
- Same cache structure for all LODs
- Enables pan/zoom cache reuse across all zoom levels

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

All LODs use the same unified tile-based path with AudioAccessor.

```
Client subscribes with viewport { start, end, width_px }
                ↓
tilesForViewport() → selects LOD based on pixels/sec
                ↓
┌─────────────────────────────────────────┐
│ For each item overlapping viewport:     │
│   - Calculate tile range for viewport   │
│   - Create AudioAccessor (lazy, once)   │
│   - For each tile in range:             │
│     - Check tile cache                  │
│     - If hit: use cached tile           │
│     - If miss: generate via accessor    │
│   - Destroy accessor                    │
│   - Return tiles as JSON                │
└─────────────────────────────────────────┘
```

**Key optimizations:**

- AudioAccessor created lazily (only on first cache miss)
- Single accessor reused for all tiles of an item
- 4000 Hz sample rate (11x faster than 44100 Hz)

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

| File | Purpose |
|------|---------|
| `extension/src/peaks_generator.zig` | `generateTileViaAccessor()` for all LODs |
| `extension/src/peaks_tile.zig` | Tile cache infrastructure, LOD configs |
| `extension/src/main.zig` | Routes viewport requests to tile generation |
| `extension/src/peaks_subscriptions.zig` | Viewport support, track subscription management |

---

## Summary

| LOD | Resolution | Tile Duration | Source |
|-----|------------|---------------|--------|
| 0 | 1 peak/sec | 64s | AudioAccessor |
| 1 | 10 peaks/sec | 8s | AudioAccessor |
| 2 | 400 peaks/sec | 0.5s | AudioAccessor |

This unified approach:

1. Uses `AudioAccessor` for all LODs (works reliably on ARM64 macOS)
2. Tile-based caching enables efficient pan/zoom at any zoom level
3. LRU eviction keeps memory bounded (~3.2 MB max)
4. Simpler code with single generation path
