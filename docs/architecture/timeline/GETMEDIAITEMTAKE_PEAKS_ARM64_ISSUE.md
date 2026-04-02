# GetMediaItemTake_Peaks — Investigation Results

> **Status**: DEBUNKED (2026-04-02) — No ARM64 ABI bug exists. Original diagnosis was wrong.

## Summary

The original belief was that `GetMediaItemTake_Peaks` via `GetFunc()` was broken on ARM64 macOS. A Lua bridge was built to work around this. **Systematic testing on REAPER 7.67 proves the API works identically from C, Zig, and Lua** — there is no GetFunc ABI issue.

## What Actually Happened

The original tests used a **fixed 32 peaks** at increasing peakrates starting at **position 0.0** of items that began with silence. At high peakrates, 32 peaks covers a tiny time window (e.g., 32/256 = 0.125 seconds), which fell entirely within the silent region at the start of the test audio files.

The "Lua works but Zig doesn't" conclusion was likely due to different test parameters (different num_peaks or starttime values) between the Lua and Zig tests, not a fundamental API difference.

## Evidence

### Test methodology

Built a minimal C plugin (`test_peaks_plugin/reaper_test_peaks.c`) that calls `GetMediaItemTake_Peaks` via `GetFunc()` — identical to how Zig calls it. Also built an equivalent Lua script (`test_peaks_plugin/test_peaks.lua`). Both produce identical output format for direct comparison.

### C plugin and Lua produce identical results

Tested on the same items in the same REAPER session:

**Long mono item (184.7s, pos=0.0):**
- C plugin: ALL ZERO at rate=32+ with 32 peaks
- Lua: ALL ZERO at rate=32+ with 32 peaks (identical)

**Long stereo item (187.0s, pos=0.0):**
- C plugin: ALL ZERO at rate=64+ with 32 peaks
- Lua: ALL ZERO at rate=64+ with 32 peaks (identical)

**Short mono item (2.17s, pos=80.0, section of 183s source):**
- C plugin: All rates work, up to 1024/s
- Lua: All rates work (identical)

### Realistic viewport/tile requests all work

When using parameters that match actual waveform rendering (num_peaks proportional to window duration):

```
--- Viewport simulation (10s window at +30s) ---
LOD0 (0.0625/s, 1 peak):    max=0.1789
LOD1 (0.25/s, 2 peaks):     max=0.1789
LOD2 (1/s, 10 peaks):       max=0.1789
LOD3 (4/s, 40 peaks):       max=0.1789
LOD4 (16/s, 160 peaks):     max=0.1789
LOD5 (64/s, 640 peaks):     max=0.1789
LOD6 (256/s, 2560 peaks):   max=0.1789

--- Tile requests (256 peaks/tile) ---
All 7 LOD levels: data returned successfully

--- 5s slice at 256/s (1280 peaks) ---
Start, 25%, middle, 75%, end: all return data

--- Window size sweep at rate=256 ---
4, 8, 16, 32, 64, 128, 256, 512, 1024, 2560 peaks: all return data
```

**Zero failures across all realistic request patterns.**

### GetMediaSourceNumChannels works correctly

Also previously believed broken on ARM64. Test results:
- Mono file: returns 1 (correct)
- Stereo file: returns 2 (correct)

## Why the original tests showed zeros

The original test pattern was: fixed `num_peaks=32`, sweep `peakrate` from low to high, `starttime=item_position`.

At `peakrate=256` with `num_peaks=32`, the time window is only `32/256 = 0.125 seconds`. If the audio file starts with silence (common for vocal tracks with count-ins, etc.), this window contains no audio data. The API correctly returns zero peaks for a silent region.

At lower peakrates (e.g., `peakrate=0.5`), the same 32 peaks covers `32/0.5 = 64 seconds`, which extends well past any initial silence, so data is returned.

This created the illusion of a peakrate-dependent failure when it was actually a content-dependent result of the test design.

## Implications for the codebase

### Lua bridge is unnecessary

The Lua bridge (`reamo_internal_fetch_peaks.lua` and the 8 `Reamo_*` API functions in `main.zig`) was built to work around a non-existent bug. `GetMediaItemTake_Peaks` can be called directly from Zig via `GetFunc()`.

The Lua bridge happens to work because it requests appropriately-sized tile windows (256 peaks at the LOD peakrate), not because Lua has a different code path.

### GetMediaSourceNumChannels can be trusted

The current code has several workarounds for "unreliable" channel count:
- `items.zig:487`: "GetMediaSourceNumChannels is broken (returns 1 for stereo files)"
- `peaks_generator.zig:954`: "Always request stereo, detect mono by comparing L/R later"
- `peaks_tile.zig`: "Epoch = hash of source pointer (NOT channel count - unreliable)"

These workarounds can be removed. Trust the API, request the actual channel count, and tell the frontend directly whether the source is mono or stereo.

### Simplification opportunities

1. **Remove Lua bridge** — Call `GetMediaItemTake_Peaks` directly from Zig. Eliminates: 8 vararg wrapper functions, Lua script, `Main_OnCommand` synchronization, binary packing/unpacking overhead.

2. **Trust GetMediaSourceNumChannels** — Remove L/R comparison mono detection. Request actual channel count. Send channel info to frontend directly.

3. **Remove AudioAccessor fallback** — The `genTileAccessor` path (reads raw samples, computes peaks manually) was a fallback for the "broken" API. No longer needed.

4. **Simplify epoch computation** — Can include channel count in epoch hash now that the API is reliable.

## LOD System (unchanged, still valid)

| LOD | Viewport Duration | Peakrate | Tile Duration |
|-----|-------------------|----------|---------------|
| 0 | > 5hr | 0.0625/s | 4096s |
| 1 | 80min-5hr | 0.25/s | 1024s |
| 2 | 20-80min | 1/s | 256s |
| 3 | 5-20min | 4/s | 64s |
| 4 | 75s-5min | 16/s | 16s |
| 5 | 20-75s | 64/s | 4s |
| 6 | < 20s | 256/s | 1s |

All LODs use 256 peaks per tile. LOD selection based on viewport duration.

## Cache System (unchanged, still valid)

- Tiles cached by `(take_guid, epoch, lod, tile_index)`
- Source replaced -> new epoch -> old tiles orphaned automatically
- Cache survives pan/zoom at same LOD (100% hit rate when panning)

## Lessons actually learned

1. **Test with realistic parameters** — Fixed num_peaks sweeps are misleading. Use `num_peaks = peakrate * window_duration` to match real usage.
2. **Test at multiple positions** — Starting at position 0 may hit silence. Test at 25%, 50%, 75% of item length.
3. **Compare C and Lua side-by-side** — Before concluding "Lua works but C doesn't", run identical parameters through both and compare output.
4. **Silent regions are not bugs** — The API returning zeros for a silent region is correct behavior.
5. **ARM64 PAC is strict** — This lesson from the Lua bridge work remains valid for other vararg interop.
6. **Viewport-based fetching is still critical** — Fetching entire items at high peakrates wastes memory. Only fetch visible tiles.

## Still valid from original work

- `starttime` must be PROJECT time (timeline position), not item-relative
- Section sources: traverse to root via `GetMediaSourceParent` loop
- LOD change detection needs explicit `force_broadcast` flag
- ARM64 PAC: use real memory addresses for double return values in vararg wrappers

## Test artifacts

- `test_peaks_plugin/reaper_test_peaks.c` — Minimal C plugin (builds on macOS + Windows)
- `test_peaks_plugin/test_peaks.lua` — Equivalent Lua script for comparison
- `test_peaks_plugin/Makefile` — Build targets for macOS/Windows
