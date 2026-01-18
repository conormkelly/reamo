# REAmo Peaks Architecture: Complete Implementation Plan

## Problem Statement

REAmo's timeline shows waveform "blobs" for audio items across multiple tracks. The current implementation uses **fixed 30 peaks per item regardless of zoom level**, causing waveforms to become useless at precision zoom levels.

### The Resolution Problem (Quantified)

| Item Duration | Current Peaks | Resolution | At 30s zoom | At 1s zoom |
|---------------|---------------|------------|-------------|------------|
| 30s | 30 | 1 peak/sec | 30 peaks visible | 1 peak visible |
| 5 min | 30 | 1 peak/10s | 3 peaks visible | 0.1 peaks |
| 1 hour | 30 | 1 peak/2min | 0.25 peaks | 0.008 peaks |

**Root cause**: Fixed-resolution peaks don't scale across the 3600× zoom range (1s to 1h).

### Current Zoom Configuration

```typescript
// useViewport.ts - Zoom steps
export const ZOOM_STEPS = [1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600] as const;
//                        ↑↑↑ NEW: 1s, 2s, 3s for precision editing

// usePinchGesture.ts
const MIN_DURATION = 1;  // Changed from 5 to allow 1s zoom
```

### Success Criteria

| Criterion | Target | Validation |
|-----------|--------|------------|
| Waveforms useful at 1s zoom | See individual transients | Visual inspection |
| No perceptible lag on zoom | Debounced refetch after gesture | < 300ms settle time |
| Pan is instant | Pre-fetched buffer covers typical pan | 0ms from cache |
| Initial load is fast | Waveforms appear quickly on bank switch | < 500ms |
| REAPER stays responsive | Peak generation doesn't block UI | No frame drops |
| Cache is effective | Avoid redundant computation | > 80% hit rate |
| Bandwidth is reasonable | Don't flood WebSocket | < 500KB per update |

---

## Key Discovery: REAPER Already Has LOD

**The `GetMediaItemTake_Peaks` API handles LOD selection internally via its `peakrate` parameter.** This eliminates the need to build our own peak pyramid—we request the resolution we need and REAPER selects from pre-generated `.reapeaks` mipmaps.

### REAPER's Built-in Mipmap Tiers (v7.x)

| Tier | Resolution | Division Factor (@44.1kHz) | Use Case |
|------|------------|---------------------------|----------|
| 1 | ~400 peaks/sec | 110 | Detailed editing |
| 2 | ~10 peaks/sec | 4,410 | Normal arrangement |
| 3 | ~1 peak/sec | 44,100 | Full-project overview |

### The API (Validated from REAPER SDK + ReaTeam Scripts)

```c++
int GetMediaItemTake_Peaks(
    MediaItem_Take* take,
    double peakrate,           // Peaks/sec - REAPER auto-selects mipmap!
    double starttime,          // PROJECT time (timeline position)
    int numchannels,
    int numsamplesperchannel,  // Number of peak samples to retrieve
    int want_extra_type,       // 0 = normal, 115/'s' = spectral
    double* buf                // Output buffer
);

// Return value bits:
// 0-19:  Actual sample count returned
// 20-23: Output mode (0 = interpolated from coarser mipmap, 1+ = native resolution)
//        IMPORTANT: mode=0 is VALID DATA, not an error! Only check actual_samples == 0 for failure.
// 24:    Extra type available
```

### ⚠️ CRITICAL: starttime Parameter

**`GetMediaItemTake_Peaks` expects PROJECT time (absolute timeline position).**

| API | `starttime` meaning |
|-----|---------------------|
| `GetMediaItemTake_Peaks` | Project timeline position (e.g., item's D_POSITION) |
| `PCM_Source_GetPeaks` | Source-relative time (0.0 = start of audio file) |

If you pass `starttime=0.0` to `GetMediaItemTake_Peaks` and your item starts at 1894s on the timeline, you'll get zeros because there's no audio at project time 0. **Always pass the item's project position** (`D_POSITION`) as the base for `starttime`.

```c
// WRONG - returns zeros if item isn't at project start
GetMediaItemTake_Peaks(take, peakrate, 0.0, ...);

// CORRECT - use item's timeline position
double item_pos = GetMediaItemInfo_Value(item, "D_POSITION");
GetMediaItemTake_Peaks(take, peakrate, item_pos, ...);
```

**Note on take properties**: The API automatically handles D_STARTOFFS (trim) and D_PLAYRATE (time stretch) internally. You don't need to adjust parameters for these—just pass the project timeline position you want peaks for.

---

## ⚠️ CRITICAL CORRECTION: Buffer Layout

### ❌ WRONG (What We Previously Assumed)

```
4 separate sequential blocks:
[L_max_0, L_max_1, ..., L_max_N]   // All left maxes
[R_max_0, R_max_1, ..., R_max_N]   // All right maxes  
[L_min_0, L_min_1, ..., L_min_N]   // All left mins
[R_min_0, R_min_1, ..., R_min_N]   // All right mins
```

### ✅ CORRECT (Actual Layout)

```
2 blocks with CHANNEL-INTERLEAVED samples within each block:

BLOCK 1 - MAXIMUMS (indices 0 to numchannels*numsamplesperchannel - 1):
[L_max_0, R_max_0, L_max_1, R_max_1, ..., L_max_N, R_max_N]

BLOCK 2 - MINIMUMS (indices numchannels*numsamplesperchannel to end):
[L_min_0, R_min_0, L_min_1, R_min_1, ..., L_min_N, R_min_N]
```

### Buffer Size Calculation

```
buffer_size = numchannels * numsamplesperchannel * 2  // max block + min block
            = numchannels * numsamplesperchannel * 3  // if want_extra_type != 0
```

### Index Formulas (0-indexed)

For sample `i` (0 to numsamplesperchannel-1), channel `ch` (0 to numchannels-1):

```
max_index = i * numchannels + ch
min_index = (numchannels * numsamplesperchannel) + i * numchannels + ch
```

**This is the likely cause of the misalignment bug!** The previous code assumed separate L/R blocks, but the actual layout interleaves channels within each block.

---

## Corrected Lua Example

```lua
-- Corrected peak retrieval matching REAPER's actual buffer layout
function GetItemPeaksForDisplay(item, peakrate)
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then return nil end
    
    local source = reaper.GetMediaItemTake_Source(take)
    local numchannels = reaper.GetMediaSourceNumChannels(source)
    
    -- Get item position and length in PROJECT TIME
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    
    -- Calculate number of peak samples needed
    local numsamplesperchannel = math.ceil(item_len * peakrate)
    
    -- Buffer size: 2 blocks (max + min), each with interleaved channels
    local buf_size = numchannels * numsamplesperchannel * 2
    local buf = reaper.new_array(buf_size)
    
    -- starttime = PROJECT TIME (item's position on timeline)
    local retval = reaper.GetMediaItemTake_Peaks(
        take, 
        peakrate, 
        item_pos,         -- PROJECT TIME, not relative!
        numchannels, 
        numsamplesperchannel, 
        0,                -- 0 = normal peaks
        buf
    )
    
    -- Decode return value
    local actual_samples = retval & 0xFFFFF
    -- NOTE: mode=0 is VALID (interpolated from coarser mipmap), NOT an error!
    -- mode=1+ means native resolution. Only check actual_samples for failure.

    if actual_samples == 0 then
        return nil, "no_samples"
    end
    
    -- Parse buffer with CORRECT layout (channel-interleaved within blocks)
    local peaks = {}
    local block_size = numchannels * actual_samples
    
    for i = 0, actual_samples - 1 do
        peaks[i + 1] = {}
        for ch = 0, numchannels - 1 do
            -- CORRECT indexing: channels interleaved within each block
            local max_idx = i * numchannels + ch + 1           -- +1 for Lua 1-indexing
            local min_idx = block_size + i * numchannels + ch + 1
            
            peaks[i + 1][ch + 1] = {
                min = buf[min_idx],
                max = buf[max_idx]
            }
        end
    end
    
    return peaks, actual_samples, numchannels
end

-- Test script - run this in REAPER to verify
local item = reaper.GetSelectedMediaItem(0, 0)
if item then
    local peaks, count, channels = GetItemPeaksForDisplay(item, 100)
    if peaks then
        reaper.ShowConsoleMsg(string.format("Got %d samples, %d channels\n", count, channels))
        -- Print first few peaks to verify
        for i = 1, math.min(5, count) do
            local p = peaks[i]
            if channels == 2 then
                reaper.ShowConsoleMsg(string.format(
                    "  [%d] L: %.3f to %.3f, R: %.3f to %.3f\n",
                    i, p[1].min, p[1].max, p[2].min, p[2].max
                ))
            else
                reaper.ShowConsoleMsg(string.format(
                    "  [%d] %.3f to %.3f\n",
                    i, p[1].min, p[1].max
                ))
            end
        end
    else
        reaper.ShowConsoleMsg("Failed: " .. tostring(count) .. "\n")
    end
end
```

---

## Corrected Zig Implementation

```zig
/// Generate peaks for a single item using REAPER's GetMediaItemTake_Peaks API.
/// REAPER automatically selects the appropriate mipmap tier based on peakrate:
///   - ~400 peaks/sec (finest)
///   - ~10 peaks/sec (medium)
///   - ~1 peak/sec (coarse)
/// We request exactly what we need and let REAPER handle LOD selection and interpolation.
fn generatePeaksForItem(
    allocator: Allocator,
    api: anytype,
    take: *anyopaque,
    length: f64,          // Item's duration on timeline (D_LENGTH)
    num_peaks: usize,     // Desired output peaks
    item_peaks: *ItemPeaks,  // Contains .position (item's D_POSITION on timeline)
) bool {
    // 1. Get channel count from source
    const source = api.getTakeSource(take) orelse return false;
    const source_channels = api.getMediaSourceChannels(source);
    if (source_channels <= 0) return false;
    const num_channels: usize = @min(@as(usize, @intCast(source_channels)), 2);

    // 2. Calculate peakrate to get exactly num_peaks covering the full item
    // REAPER will automatically select/interpolate from appropriate mipmap tier
    const peakrate: f64 = @as(f64, @floatFromInt(num_peaks)) / length;

    // 3. Allocate buffer: 2 blocks (max + min), each with interleaved channels
    const buf_size = num_channels * num_peaks * 2;
    const reaper_buf = allocator.alloc(f64, buf_size) catch return false;
    defer allocator.free(reaper_buf);

    // 4. starttime = PROJECT TIME (item's position on timeline)
    const item_position = item_peaks.position;  // D_POSITION

    // 5. Call REAPER API
    const result = api.getMediaItemTakePeaks(
        take,
        peakrate,
        item_position,       // PROJECT TIME
        @intCast(num_channels),
        @intCast(num_peaks),
        reaper_buf,
    );

    // 6. Parse return value
    const actual_peaks: usize = @intCast(result & 0xFFFFF);
    // NOTE: mode=0 is VALID (interpolated from coarser mipmap), NOT an error!
    // mode=1+ means native resolution. Only check actual_peaks for failure.

    if (actual_peaks == 0) return false;

    // 7. Parse buffer with CORRECT layout (channel-interleaved within blocks)
    const peaks_to_use = @min(actual_peaks, num_peaks);
    const block_size = num_channels * peaks_to_use;

    for (0..peaks_to_use) |p| {
        for (0..num_channels) |ch| {
            const our_idx = p * num_channels + ch;

            // CORRECT: channels are interleaved within each block
            const max_offset = p * num_channels + ch;              // Within first block
            const min_offset = block_size + p * num_channels + ch; // Within second block

            item_peaks.peak_max[our_idx] = reaper_buf[max_offset];
            item_peaks.peak_min[our_idx] = reaper_buf[min_offset];
        }
    }

    // 8. Zero out any remaining peaks if we got fewer than requested
    for (peaks_to_use..num_peaks) |p| {
        for (0..num_channels) |ch| {
            const idx = p * num_channels + ch;
            item_peaks.peak_max[idx] = 0;
            item_peaks.peak_min[idx] = 0;
        }
    }

    item_peaks.num_peaks = num_peaks;
    item_peaks.num_channels = num_channels;
    return true;
}
```

**Key insight**: No MIN_PEAKRATE or downsampling needed! REAPER accepts any peakrate and returns valid interpolated data from the nearest available mipmap tier. mode=0 in the return value means interpolated data (VALID), not "not ready".

---

## Diagnostic Lua Script (Run This First!)

Before implementing the fix, run this script in REAPER to verify the buffer layout empirically:

```lua
-- DIAGNOSTIC: Verify GetMediaItemTake_Peaks buffer layout
-- Select an audio item and run this script

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
    reaper.ShowConsoleMsg("Please select an audio item first!\n")
    return
end

local take = reaper.GetActiveTake(item)
if not take or reaper.TakeIsMIDI(take) then
    reaper.ShowConsoleMsg("Please select an audio (non-MIDI) item!\n")
    return
end

local source = reaper.GetMediaItemTake_Source(take)
local numchannels = reaper.GetMediaSourceNumChannels(source)
local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

reaper.ShowConsoleMsg(string.format("\n=== DIAGNOSTIC: GetMediaItemTake_Peaks Buffer Layout ===\n"))
reaper.ShowConsoleMsg(string.format("Item position: %.3f s\n", item_pos))
reaper.ShowConsoleMsg(string.format("Item length: %.3f s\n", item_len))
reaper.ShowConsoleMsg(string.format("Channels: %d\n", numchannels))

-- Request just 4 samples to make it easy to see the layout
local numsamplesperchannel = 4
local peakrate = numsamplesperchannel / item_len
local buf_size = numchannels * numsamplesperchannel * 2
local buf = reaper.new_array(buf_size)

reaper.ShowConsoleMsg(string.format("Requesting %d samples/channel at peakrate %.2f\n", numsamplesperchannel, peakrate))
reaper.ShowConsoleMsg(string.format("Buffer size: %d\n\n", buf_size))

local retval = reaper.GetMediaItemTake_Peaks(
    take, peakrate, item_pos, numchannels, numsamplesperchannel, 0, buf
)

local actual_samples = retval & 0xFFFFF
local mode = (retval >> 20) & 0xF

reaper.ShowConsoleMsg(string.format("Return value: 0x%X\n", retval))
reaper.ShowConsoleMsg(string.format("Actual samples: %d\n", actual_samples))
-- NOTE: mode=0 is VALID (interpolated), mode=1+ is native resolution
reaper.ShowConsoleMsg(string.format("Mode: %d %s\n\n", mode, mode == 0 and "(interpolated)" or "(native)"))

if actual_samples == 0 then
    reaper.ShowConsoleMsg("No samples returned - check item selection\n")
    return
end

-- Dump raw buffer
reaper.ShowConsoleMsg("Raw buffer contents:\n")
for i = 1, buf_size do
    reaper.ShowConsoleMsg(string.format("  buf[%d] = %.4f\n", i, buf[i]))
end

reaper.ShowConsoleMsg("\n--- Interpretation if CHANNEL-INTERLEAVED (2 blocks): ---\n")
local block_size = numchannels * actual_samples
for i = 0, actual_samples - 1 do
    local line = string.format("Sample %d: ", i)
    for ch = 0, numchannels - 1 do
        local max_idx = i * numchannels + ch + 1
        local min_idx = block_size + i * numchannels + ch + 1
        line = line .. string.format("ch%d[%.3f,%.3f] ", ch, buf[min_idx], buf[max_idx])
    end
    reaper.ShowConsoleMsg(line .. "\n")
end

reaper.ShowConsoleMsg("\n--- Interpretation if SEPARATE BLOCKS (4 blocks for stereo): ---\n")
if numchannels == 2 then
    for i = 0, actual_samples - 1 do
        local l_max_idx = i + 1
        local r_max_idx = actual_samples + i + 1
        local l_min_idx = actual_samples * 2 + i + 1
        local r_min_idx = actual_samples * 3 + i + 1
        reaper.ShowConsoleMsg(string.format(
            "Sample %d: L[%.3f,%.3f] R[%.3f,%.3f]\n",
            i, buf[l_min_idx], buf[l_max_idx], buf[r_min_idx], buf[r_max_idx]
        ))
    end
else
    for i = 0, actual_samples - 1 do
        local max_idx = i + 1
        local min_idx = actual_samples + i + 1
        reaper.ShowConsoleMsg(string.format(
            "Sample %d: [%.3f,%.3f]\n",
            i, buf[min_idx], buf[max_idx]
        ))
    end
end

reaper.ShowConsoleMsg("\n=== Compare the two interpretations to see which makes sense! ===\n")
reaper.ShowConsoleMsg("The CORRECT one will show min <= max for all samples.\n")
```

---

## Architecture: Tile-Based Caching Over REAPER's LOD

While REAPER handles resolution selection, we add tile-based caching to avoid re-requesting on pan and enable efficient prefetching.

### LOD Mapping (3 Levels)

```typescript
function selectLOD(viewportDuration: number, viewportPixels: number): number {
  const pixelsPerSecond = viewportPixels / viewportDuration;
  
  if (pixelsPerSecond > 200) return 2;   // Fine: ~400 peaks/sec
  if (pixelsPerSecond > 5) return 1;     // Medium: ~10 peaks/sec
  return 0;                               // Coarse: ~1 peak/sec
}

// Examples:
// 1s viewport, 400px → LOD 2 (fine)
// 30s viewport, 400px → LOD 1 (medium)
// 5min viewport, 400px → LOD 0 (coarse)
```

### Tile Structure

```typescript
const TILE_CONFIG = {
  0: { duration: 64, peakrate: 1 },    // ~64 peaks/tile
  1: { duration: 8, peakrate: 10 },    // ~80 peaks/tile
  2: { duration: 0.5, peakrate: 400 }, // ~200 peaks/tile
};
```

### Cache Key Format

```
peaks:{takeGuid}:v{epoch}:lod{level}:tile{index}
```

- **epoch**: Version counter, incremented on source audio edit
- **level**: 0-2 mapping to REAPER's mipmap tiers
- **index**: Tile position = floor(startTime / tileDuration)

---

## API Changes

### Frontend Subscription (New)

```typescript
interface PeaksSubscription {
  trackRange: { start: number; end: number };
  viewport: {
    startTime: number;
    endTime: number;
    widthPixels: number;
  };
  bufferRatio: number;  // 0.5 = 50% buffer each side
}
```

### Backend Response

```typescript
interface PeaksResponse {
  takeGuid: string;
  epoch: number;
  tiles: Array<{
    lodLevel: number;
    tileIndex: number;
    startTime: number;
    endTime: number;
    peaks: Int8Array;  // [min0, max0, min1, max1...] per channel, interleaved
  }>;
}
```

### Backend Implementation (Zig) - Tile Fetching

```zig
fn getPeaksForTile(
    take: *anyopaque,
    lod: u8,
    tile_index: u32,
    api: anytype,
    allocator: Allocator,
) ![]Peak {
    const config = TILE_CONFIG[lod];
    
    // Get item's project position
    const item = api.getMediaItemTakeItem(take) orelse return error.NoItem;
    const item_pos = api.getMediaItemInfoValue(item, "D_POSITION");
    
    // Calculate tile's project time position
    const tile_start_relative = @as(f64, @floatFromInt(tile_index)) * config.duration;
    const tile_start_project = item_pos + tile_start_relative;  // PROJECT TIME!
    
    const num_peaks = @as(u32, @intFromFloat(config.duration * config.peakrate));
    
    const source = api.getTakeSource(take) orelse return error.NoSource;
    const num_channels = @as(usize, @intCast(api.getMediaSourceNumChannels(source)));
    
    const buf_size = num_channels * num_peaks * 2;
    var buf = try allocator.alloc(f64, buf_size);
    defer allocator.free(buf);
    
    const result = api.getMediaItemTakePeaks(
        take,
        config.peakrate,
        tile_start_project,   // PROJECT TIME
        @intCast(num_channels),
        @intCast(num_peaks),
        buf,
    );
    
    const actual_peaks = @as(usize, @intCast(result & 0xFFFFF));
    // NOTE: mode=0 is VALID (interpolated data), NOT an error!
    // Only check actual_peaks for failure.
    _ = @as(u4, @intCast((result >> 20) & 0xF)); // mode (unused)

    if (actual_peaks == 0) return error.NoPeaks;
    
    // Parse with CORRECT layout
    var peaks = try allocator.alloc(Peak, actual_peaks);
    const block_size = num_channels * actual_peaks;
    
    for (0..actual_peaks) |p| {
        peaks[p] = Peak{
            .left_min = buf[p * num_channels + 0],
            .left_max = buf[block_size + p * num_channels + 0],
            .right_min = if (num_channels > 1) buf[p * num_channels + 1] else 0,
            .right_max = if (num_channels > 1) buf[block_size + p * num_channels + 1] else 0,
        };
    }
    
    return peaks;
}
```

---

## Gesture Handling

### State Machine

```
IDLE → (gesture start) → ACTIVE → (gesture end) → SETTLING → (debounce) → IDLE
                           ↓
                    MOMENTUM (if velocity > threshold)
```

### Timing Parameters

| Gesture | Strategy | Timing | Rationale |
|---------|----------|--------|-----------|
| Pinch-to-zoom | Debounce | 200ms after end | Only final zoom matters |
| Pan/scroll | Throttle | 100ms during | Predictive prefetch |
| Momentum | Predictive | Along velocity | Smooth deceleration |

### During ACTIVE State

- Apply CSS/canvas transforms only (no data fetch)
- Render from cached tiles at nearest-available LOD
- Calculate predicted final viewport

### On SETTLING → IDLE

- Fetch tiles for final viewport at optimal LOD
- Prefetch buffer tiles (50% viewport each direction)
- Prefetch adjacent LOD (coarser for zoom-out prep)

### Buffer Sizing

```typescript
const BUFFER_RATIO = 0.5;

function getTilesToFetch(viewport: Viewport, lod: number): Tile[] {
  const config = TILE_CONFIG[lod];
  const bufferedStart = viewport.startTime - (viewport.duration * BUFFER_RATIO);
  const bufferedEnd = viewport.endTime + (viewport.duration * BUFFER_RATIO);
  
  const startTile = Math.floor(Math.max(0, bufferedStart) / config.duration);
  const endTile = Math.ceil(bufferedEnd / config.duration);
  
  return range(startTile, endTile).map(i => ({ lod, tileIndex: i }));
}
```

---

## Avoiding the Slinky Artifact

The "slinky artifact" occurs when different LOD levels show inconsistent peak positions. **Solution: Coarser levels derive from finer levels, not raw audio.**

```typescript
function generateLODPyramid(finestPeaks: Int8Array): Map<number, Int8Array> {
  const pyramid = new Map();
  pyramid.set(2, finestPeaks);  // LOD 2 from GetMediaItemTake_Peaks
  
  // LOD 1 = aggregate pairs from LOD 2
  const lod1 = aggregatePeaks(pyramid.get(2), 2);
  pyramid.set(1, lod1);
  
  // LOD 0 = aggregate from LOD 1
  const lod0 = aggregatePeaks(pyramid.get(1), 4);
  pyramid.set(0, lod0);
  
  return pyramid;
}

function aggregatePeaks(source: Int8Array, factor: number): Int8Array {
  const result = new Int8Array(source.length / factor);
  for (let i = 0; i < result.length; i += 2) {
    let min = 127, max = -128;
    for (let j = 0; j < factor; j += 2) {
      min = Math.min(min, source[i * factor / 2 + j]);
      max = Math.max(max, source[i * factor / 2 + j + 1]);
    }
    result[i] = min;
    result[i + 1] = max;
  }
  return result;
}
```

**Note**: Since we're using REAPER's built-in mipmaps which are already hierarchically computed, the slinky artifact should be minimal. This code is for edge cases or if we need finer intermediate levels.

---

## Cache Strategy

### Memory Budget (Mobile)

- Per tile: ~200 peaks × 2 bytes × 2 channels = **800 bytes**
- Cache limit: 500 tiles = **~400KB**
- LRU eviction priority: viewport > buffer > recently-viewed

### Invalidation Rules

| Event | Action |
|-------|--------|
| Source audio edit | Increment epoch for takeGuid |
| Item move/resize | No invalidation (peaks still valid) |
| Take swap | Different takeGuid = different cache |
| Project reload | Cold cache, regenerate on demand |

### Target Hit Rates

| Scenario | Expected Hit Rate |
|----------|-------------------|
| Pan within buffer | 100% |
| Return to previous zoom | ~95% (LRU cached) |
| Zoom in/out one level | ~80% (partial overlap) |
| Jump to new region | 0% (cold) |

---

## Current Codebase Files (For Implementation)

| File | Purpose | Changes Needed |
|------|---------|----------------|
| `frontend/src/hooks/usePeaksSubscription.ts` | Subscription hook | Add viewport params |
| `frontend/src/components/Timeline/MultiTrackLanes.tsx` | Waveform rendering | Tile-based rendering |
| `frontend/src/components/Timeline/hooks/usePinchGesture.ts` | Zoom gesture | Add debounce |
| `frontend/src/hooks/useViewport.ts` | Viewport state | Expose for subscription |
| `extension/src/peaks_subscriptions.zig` | Backend subscription | Add viewport handling |
| `extension/src/peaks_generator.zig` | Peak computation | **Fix buffer parsing!** |
| `extension/src/peaks_cache.zig` | Backend cache | Add tile-based keys |

---

## Migration Path

### Week 1: Fix Buffer Parsing & Verify

- [ ] Run diagnostic Lua script to confirm buffer layout
- [ ] Fix buffer parsing in `peaks_generator.zig` (channel-interleaved)
- [ ] Verify output matches REAPER's waveforms at equivalent resolution
- [ ] Add epoch tracking per take

### Week 2: Add Tile-Based API

- [ ] Implement `getPeakTiles(takeGuid, lod, tileIndices)` endpoint
- [ ] Add LOD selection logic
- [ ] Implement tile cache with new key format
- [ ] Keep old API working (backward compat)

### Week 3: Frontend Integration

- [ ] Update `usePeaksSubscription` with viewport awareness
- [ ] Implement client-side tile cache with LRU
- [ ] Replace fixed-peaks rendering with tile-based
- [ ] Add LOD blending during zoom animation

### Week 4: Gesture Optimization

- [ ] Add 200ms debounce to zoom handler
- [ ] Implement 100ms throttled pan prefetch
- [ ] Add momentum-based trajectory prediction
- [ ] Tune parameters on actual devices

---

## Constraints & Limits

| Constraint | Value | Source |
|------------|-------|--------|
| Max peaks per item | 200 | `MAX_PEAKS_PER_ITEM` in backend |
| Peaks polling tier | LOW (1-5Hz) | Current architecture |
| Max tracks subscribed | 4 (visible lanes) | Viewport-driven |
| Target bandwidth | < 500KB/update | Mobile constraint |
| Target memory | < 400KB peaks | Mobile constraint |

---

## Summary of Corrections

| Issue | Original (Wrong) | Corrected |
|-------|------------------|-----------|
| Buffer layout | 4 separate blocks: [L_max][R_max][L_min][R_min] | 2 blocks with interleaved channels: [LR_max interleaved][LR_min interleaved] |
| Max index formula | `ch * actual_peaks + p` | `p * num_channels + ch` |
| Min index formula | `(num_channels + ch) * actual_peaks + p` | `block_size + p * num_channels + ch` |

---

## Summary

The solution combines:

1. **REAPER's built-in LOD** via `GetMediaItemTake_Peaks` with `peakrate` parameter
2. **Time-slicing** via `starttime` parameter (PROJECT TIME, not relative!)
3. **Correct buffer parsing** (channel-interleaved within max/min blocks)
4. **Tile-based caching** with quantized boundaries and 3 LOD levels
5. **Debounced gestures** (200ms zoom, 100ms pan throttle)
6. **50% buffer prefetch** for instant pan response

This delivers useful waveforms at 1-second zoom while maintaining >80% cache hit rates and keeping REAPER responsive.
