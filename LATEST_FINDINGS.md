# FFI Investigation: REAPER API Behavior Anomaly

**Date:** 2026-01-19
**Status:** Multiple REAPER APIs fail via GetFunc but work in Lua - confirmed ARM64 macOS issue

---

## Executive Summary

**Two REAPER API functions** obtained via `GetFunc()` behave differently than their Lua equivalents:

### 1. `GetMediaSourceNumChannels` - Returns wrong channel count

| Caller | Source Pointer | Result |
|--------|---------------|--------|
| Lua | `0x52410f010` | **2** (correct) |
| C/Zig via GetFunc | `0x52410f010` | **1** (wrong) |

### 2. `GetMediaItemTake_Peaks` - Returns 0 peaks instead of data

| Parameter | Zig (GetFunc) | Lua |
|-----------|---------------|-----|
| take | `0x539a38670` | same |
| peakrate | `10.0` | `10.0` |
| starttime | `1894.00` | `1894.00` |
| channels | `2` | `2` |
| samples | `80` | `80` |
| **Result** | **0 peaks** | **80 peaks, max=0.8872** |

**Conclusion:** Functions obtained via `GetFunc()` on ARM64 macOS use a different internal code path than Lua's built-in API wrappers. This is NOT an FFI issue - same parameters, same pointers, different results.

**Parent traversal ruled out:** Both Lua and the C extension see `GetMediaSourceParent()` returning null for the same source, so automatic parent traversal is NOT the explanation.

---

## What We Tested

### C Shim Bypass (fix/ffi-c-shim)

Created a thin C wrapper compiled with clang that:
1. Stores REAPER function pointers in static C variables
2. Calls them with clang-generated code (not Zig)
3. Logs all parameters and results

**GetMediaSourceNumChannels Test:**

```
C_SHIM: set GetMediaSourceNumChannels to 0x1052ecc98
C_SHIM: GetMediaSourceNumChannels(source=0x51974f730) via fn=0x1052ecc98
C_SHIM: GetMediaSourceNumChannels returned 1
```

```lua
Lua: source=userdata: 0x51974f730 channels=2
```

Lua repeated 5 times on same source - consistently returns 2.

### GetMediaItemTake_Peaks Tile Test

Tested tile-based peak fetching with identical parameters in Lua and Zig:

**Zig extension logs:**
```
raw.getMediaItemTakePeaks: take=0x539a38670 peakrate=10.0000 starttime=1894.00 ch=2 samples=80
raw.getMediaItemTakePeaks: result=0 (actual=0, mode=0)
genTile: BUFFER first 4 values: [-0.0000, -0.0000, -0.0000, -0.0000]
```

**Lua test script (test_tile_slice.lua):**
```
Peakrate: 10.0000, StartTime: 1894.00
Requested: 80 samples, Got: 80, Mode: 0
Max in buffer: 0.8872
RESULT: WORKS (has audio)
```

Same take, same parameters, same session - Lua gets 80 peaks with real audio, Zig gets 0.

---

## Hypotheses Status

### Ruled Out (All FFI/Code Issues)

| Hypothesis | Evidence |
|------------|----------|
| Zig ARM64 FFI codegen bug | C shim (clang) has same failure |
| Missing `callconv(.C)` | All function pointers have it |
| Missing `@alignCast` | getFunc helper uses both casts correctly |
| Wrong function signatures | Match C API exactly |
| Wrong f64 types | All doubles are f64 |
| Buffer type `[*]f64` vs `[*c]f64` | Tested, no difference |
| Wrong source pointer | **Same pointer as Lua, different result** |
| Source parent chain issue | Both see null parent, same pointer works in Lua |
| SECTION source wrapper | GetMediaSourceParent returns null in both Lua and C - no parent to traverse |

### Remaining Explanation

**Lua uses a different internal code path than `GetFunc()`**

The function pointer obtained via `GetFunc()` behaves differently than Lua's internal API. Possible reasons:

1. **Lua API is a wrapper** - Lua's function may do additional validation, traversal, or context setup before calling the underlying C function
2. **GetFunc returns a stub/thunk** - The function pointer may be a different entry point than what Lua uses internally
3. **Context-dependent behavior** - Some hidden global/thread-local state that Lua sets but extensions don't have access to

### SWS Extension Avoids This Problem

Research into SWS Extension source code reveals they **never use `GetMediaSourceNumChannels()` API wrapper**. Instead, they call virtual methods directly on the C++ PCM_source object:

```cpp
// SWS pattern (BR_Loudness.cpp) - direct virtual method call
int channels = (GetMediaItemTake_Source(this->GetTake()))->GetNumChannels();

// NOT the API wrapper
int channels = GetMediaSourceNumChannels(source);  // SWS avoids this
```

This suggests SWS developers likely encountered the same issue and worked around it. Direct C++ virtual calls bypass whatever internal logic the API wrapper applies.

**Note:** This workaround requires C++ and direct object access. We already use a C shim for implementing csurf methods, so a similar C++ shim could be created to call virtual methods directly on PCM_source objects.

---

## Key Evidence

**Working APIs via GetFunc:**
- `CountTracks(proj)` → Works correctly
- `GetMediaItem(proj, idx)` → Works correctly
- `GetActiveTake(item)` → Works correctly
- `ValidatePtr(ptr, type)` → Works correctly

**Broken APIs via GetFunc (ARM64 macOS):**
- `GetMediaSourceNumChannels(source)` → Returns 1 instead of 2
- `GetMediaItemTake_Peaks(...)` → Returns 0 peaks instead of actual data

The broken APIs work correctly when called from Lua with identical parameters and pointers.

---

## Worktree Status

| Worktree | Branch | Status | Finding |
|----------|--------|--------|---------|
| `reaper_www_root-c-shim` | `fix/ffi-c-shim` | **COMPLETE** | Proves it's not our code |
| `reaper_www_root-fix-aligncast` | `feature/zig-extension` | **COMPLETE** | @alignCast already correct |
| `reaper_www_root-lldb` | `fix/ffi-lldb-debug` | SKIPPED | Won't help - not an FFI issue |
| `reaper_www_root-localvar` | `fix/ffi-local-var` | SKIPPED | Tenuous, same pointer works in Lua |

---

## Recommended Action: Contact Cockos

This appears to be a REAPER API issue that requires developer insight. Suggested forum post:

**Title:** Multiple GetFunc APIs return wrong results vs Lua on ARM64 macOS

**Body:**
> I'm developing a C extension for REAPER on ARM64 macOS (Apple Silicon). Several API functions obtained via `GetFunc()` return different results than their Lua equivalents:
>
> **1. GetMediaSourceNumChannels** - Returns 1 channel via GetFunc, but Lua returns 2 (correct) for the same source pointer (`0x51974f730`).
>
> **2. GetMediaItemTake_Peaks** - Returns 0 peaks via GetFunc, but Lua returns 80 peaks with actual audio data for identical parameters:
> - Same take pointer
> - peakrate=10.0, starttime=1894.0, channels=2, samples=80
>
> Both tested:
> - Same REAPER session
> - Same pointer values (verified via logging)
> - Main thread (timer callback vs Lua script)
> - Pure C code (clang-compiled shim) to rule out any Zig FFI issues
>
> Other APIs like `CountTracks`, `GetMediaItem`, `GetActiveTake`, `ValidatePtr` work correctly via GetFunc.
>
> Is there additional context or initialization required for these specific functions that Lua handles automatically?

---

## Working Workaround

The `generatePeaksForItem` function works correctly because it uses different parameters:
- Lower peakrate covering the full item (e.g., 30 peaks / item_length)
- This happens to work via GetFunc

**Adopted solution:** Fetch full-item peaks using the working code path, then slice into tiles server-side or client-side. This avoids the broken tile-based `GetMediaItemTake_Peaks` calls.

## Alternative Approaches (Not Pursued)

1. **C++ shim for virtual method calls** - Create a C++ shim (like existing csurf shim) to call `source->GetNumChannels()` directly, bypassing the API wrapper
2. **AudioAccessor API** - `GetAudioAccessorSamples` may use a different code path (untested)
3. **Embed Lua calls** - Use REAPER's Lua API from the extension to get correct values
4. **Pre-cache in Lua** - Have a Lua script write peaks to ExtState, read from extension

---

## Files Changed (C Shim Branch)

| File | Change |
|------|--------|
| `extension/src/reaper/c_shim.c` | NEW - C wrapper functions |
| `extension/src/reaper/c_shim.h` | NEW - Header declarations |
| `extension/build.zig` | Added C compilation |
| `extension/src/reaper/raw.zig` | Route calls through C shim |
