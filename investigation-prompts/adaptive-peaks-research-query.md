# Research Query: Adaptive Waveform Peaks for REAPER Extension on ARM64 macOS

## Executive Summary

We're building a REAPER extension in Zig that needs adaptive-resolution waveform peaks for a web-based DAW interface. The extension runs on **ARM64 macOS (Apple Silicon)**. We've hit a confirmed, reproducible bug where `GetMediaItemTake_Peaks` obtained via `GetFunc()` fails with tile-slicing parameters, while identical parameters work perfectly in Lua.

**We need guidance on the optimal architecture given this constraint.**

---

## What We're Building

A WebSocket-based extension that streams waveform peak data to a web client. The client needs:
- **LOD 0** (overview): ~1 peak/sec for full-project navigation
- **LOD 1** (editing): ~10 peaks/sec for normal arrangement view
- **LOD 2** (precision): ~400 peaks/sec for detailed editing

Original plan: Tile-based caching where each tile is a fixed time window (64s/8s/0.5s per LOD) fetched independently via `GetMediaItemTake_Peaks`. This enables efficient pan/zoom with cache reuse.

---

## The Bug: GetFunc() vs Lua API Discrepancy

### What Works (via GetFunc in Zig)
```
peakrate = 0.02 (30 peaks / 1434s item length)
starttime = 1894.0 (exact item position on timeline)
num_samples = 30
channels = 2
=> actual=30, max=0.8872 [WORKS]
```

### What Fails (via GetFunc in Zig) - Same API, Different Params
```
peakrate = 400.0 (tile-like high resolution)
starttime = 2016.0 (item_position + 122s offset into item)
num_samples = 200
channels = 1 (API returns wrong channel count, but that's separate bug)
=> actual=0, mode=0 [FAILS - returns 0 peaks]
```

### What Works in Lua (identical parameters to failing Zig call)
```lua
-- TEST 6 from our isolation script
reaper.GetMediaItemTake_Peaks(take, 400.0, 2016.0, 2, 200, 0, buf)
=> actual=200, max=0.5312 [WORKS]
```

### Isolation Tests Performed

| Test | Peakrate | Starttime | Lua Result | Zig Result |
|------|----------|-----------|------------|------------|
| Full item (working params) | 0.02 | 1894.0 (item pos) | WORKS | WORKS |
| High peakrate only | 400.0 | 1894.0 (item pos) | WORKS | **FAILS** |
| Time offset only | 0.02 | 2016.0 (+122s) | WORKS | **untested** |
| Both (tile params) | 400.0 | 2016.0 (+122s) | WORKS | **FAILS** |

**Conclusion**: The issue appears when using high peakrate (400) via GetFunc(). Time offset may also contribute. Lua's API works with all combinations.

---

## What We've Already Tried

1. **Verified pointer values match** - Logged take pointer in both Zig and Lua, identical
2. **Verified parameters match** - Exact same peakrate, starttime, channels, num_samples
3. **Built a pure C shim** (clang-compiled) to rule out Zig FFI issues - **same failure**
4. **Checked calling convention** - Using `.c` calling convention, matches REAPER's expected ABI
5. **Checked buffer alignment** - Using heap-allocated f64 array, properly aligned
6. **Tested on main thread** - Extension runs in REAPER's main thread via timer callback

---

## Secondary Bug: GetMediaSourceNumChannels Returns Wrong Value

```
Lua:  GetMediaSourceNumChannels(source) => 2 (correct, stereo file)
Zig:  api.getMediaSourceChannels(source) => 1 (wrong)
```

This is annoying but workable - we hardcode to 2 channels and detect mono by comparing L/R peaks. **This is NOT the blocking issue.**

---

## Current Architecture

### API Layer (extension/src/reaper/raw.zig)
```zig
// Function pointer obtained via GetFunc()
getMediaItemTakePeaks: ?*const fn (
    ?*anyopaque,  // take
    f64,          // peakrate
    f64,          // starttime
    c_int,        // numchannels
    c_int,        // numsamplesperchannel
    [*]f64,       // buf
) callconv(.c) c_int = null,

// Initialized at extension load
self.getMediaItemTakePeaks = @ptrCast(getFunc("GetMediaItemTake_Peaks"));
```

### Working Code Path (generates full-item peaks)
```zig
fn generatePeaksForItem(take, length, num_peaks, item_peaks) {
    const peakrate = num_peaks / length;  // e.g., 30/1434 = 0.02
    const starttime = item_peaks.position; // exact item position

    // This works!
    api.getMediaItemTakePeaks(take, peakrate, starttime, channels, num_peaks, buf);
}
```

### Broken Code Path (generates tile-based peaks)
```zig
fn generateTileForTake(take, item_position, lod_level, tile_index) {
    const peakrate = 400.0;  // LOD 2 tile resolution
    const tile_offset = tile_index * 0.5;  // 0.5s tiles
    const starttime = item_position + tile_offset;

    // This returns 0 peaks!
    api.getMediaItemTakePeaks(take, peakrate, starttime, channels, 200, buf);
}
```

---

## Existing Infrastructure We Have

### AudioAccessor API (already wrapped)
```zig
// In raw.zig - these function pointers exist
createTakeAudioAccessor: fn(take) -> accessor
destroyAudioAccessor: fn(accessor) -> void
getAudioAccessorSamples: fn(accessor, samplerate, numchannels, starttime, numsamplesperchannel, buf) -> c_int
```

**Working usage example** in `commands/items.zig:392-560`:
- Creates accessor for take
- Reads raw samples at 44100 Hz
- Computes peaks from samples (min/max per window)
- Detects mono vs stereo

### Tile Cache (ready to use)
```zig
// In peaks_tile.zig
TileCacheKey { take_guid, epoch, lod_level, tile_index }
CachedTile { peak_min[400], peak_max[400], num_peaks, channels }
TileCache with LRU eviction (500 entries max)
```

### Subscription System
```zig
// Client subscribes with viewport
viewport: { start: f64, end: f64, width_px: u32 }
// viewportPeakrate() returns quantized LOD: 1, 10, or 400 peaks/sec
```

---

## Questions for Research

### 1. AudioAccessor Approach

Given that `GetMediaItemTake_Peaks` fails with tile parameters via GetFunc(), is `GetAudioAccessorSamples` a viable alternative?

- Does it have the same GetFunc() issues on ARM64?
- What's the performance profile? (We have working code that uses it for single items)
- Can we efficiently get samples for just a tile time range (e.g., 0.5s at a time)?
- What sample rate should we use for peak computation? (Currently using 44100)

**Our concern**: AudioAccessor reads raw samples, requiring us to compute peaks. For LOD 2 (400 peaks/sec), a 0.5s tile needs 200 peaks from ~22050 samples. Is this CPU-efficient enough for real-time streaming to multiple clients?

### 2. Full-Item Fetch + Server-Side Slicing

If AudioAccessor also has issues, we could:
1. Fetch full-item peaks using the **working** low-peakrate API
2. At higher resolution for each LOD level (e.g., fetch at 10 peaks/sec for LOD 1)
3. Slice the result into tiles in our code
4. Cache tiles for pan/zoom efficiency

**Questions**:
- Is there a practical limit on num_peaks in a single GetMediaItemTake_Peaks call?
- For a 5-minute item at 400 peaks/sec, that's 120,000 peaks (~4MB). Feasible?
- How to efficiently downsample from high-res to lower LODs?

### 3. Optimal Caching Strategy

Given the constraints, what's the best caching architecture?

**Option A**: Cache by (take_guid, LOD_level) - store full-item peaks per LOD
- Pro: Simple, uses working API
- Con: Large cache entries for long items, no pan-reuse at high LOD

**Option B**: Cache by (take_guid, LOD_level, tile_index) - tile-based but computed from full-item
- Pro: Pan/zoom cache reuse, bounded tile size
- Con: Requires slicing logic, more cache entries

**Option C**: Hybrid - full-item for LOD 0/1, tiles for LOD 2
- Pro: Balances memory vs cache hit rate
- Con: Two code paths

### 4. Known REAPER API Issues on ARM64

- Is this a known issue with GetFunc() on Apple Silicon?
- Are there REAPER forum threads or SWS discussions about this?
- SWS Extension appears to call `PCM_source::GetPeaks()` directly via C++ vtable - is this a viable workaround?

### 5. Lua Bridge (Last Resort)

If all native approaches fail, we could:
1. Have a Lua script fetch peaks and write to ExtState
2. Extension reads from ExtState

**Concerns**:
- ExtState has size limits
- Latency from polling
- Complexity of synchronization

Is this worth pursuing, or are there better alternatives?

---

## Constraints

- **Must work on ARM64 macOS** (primary development platform)
- **Extension is written in Zig** (C ABI compatible)
- **Real-time streaming** to web clients via WebSocket
- **Multiple concurrent clients** with different viewports
- **Items can be very long** (1+ hours for podcasts/music sessions)

---

## Desired Output

1. **Recommended approach** for getting tile-based adaptive peaks given the GetFunc() limitation
2. **Sample implementation sketch** if AudioAccessor is recommended
3. **Caching strategy recommendation** with rationale
4. **Any known workarounds** for the GetFunc() discrepancy on ARM64
5. **Performance considerations** for each approach

---

## Reference: REAPER's GetMediaItemTake_Peaks API

```
int GetMediaItemTake_Peaks(
    MediaItem_Take* take,
    double peakrate,        // peaks per second
    double starttime,       // PROJECT time (timeline position)
    int numchannels,        // 1=mono, 2=stereo
    int numsamplesperchannel,
    int want_extra_type,    // 0 for normal peaks
    double* buf             // size = numchannels * numsamplesperchannel * 2
)

Returns: bits 0-19 = actual sample count, bits 20-23 = mode (0=interpolated, 1+=native)

Buffer layout:
  Block 1 (Maximums): [ch0_max_0, ch1_max_0, ch0_max_1, ch1_max_1, ...]
  Block 2 (Minimums): [ch0_min_0, ch1_min_0, ch0_min_1, ch1_min_1, ...]
```

---

## Files for Context (if needed)

- `extension/src/peaks_generator.zig` - Peak generation logic (working + broken paths)
- `extension/src/peaks_tile.zig` - Tile cache data structures
- `extension/src/reaper/raw.zig` - REAPER API bindings via GetFunc()
- `extension/src/commands/items.zig:392-560` - Working AudioAccessor example
- `LATEST_FINDINGS.md` - Full debugging investigation log
- `test_tile_slice.lua` - Lua test proving API works with tile params
