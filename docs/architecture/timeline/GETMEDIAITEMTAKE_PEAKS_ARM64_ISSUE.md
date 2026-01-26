# GetMediaItemTake_Peaks ARM64 ABI Issue

> **Status**: SOLVED - Lua bridge implemented and working

## Problem

`GetMediaItemTake_Peaks` and `PCM_Source_GetPeaks` both fail on ARM64 macOS (Apple Silicon) when called via `GetFunc()` pointer casting. The same APIs work at ALL peakrates from Lua.

```
From Zig (via GetFunc):  ALL peakrates return 0
From Lua (direct):       ALL peakrates work perfectly
```

**Definitive proof** (same REAPER session, identical object pointers):

| Object | Lua | Zig |
|--------|-----|-----|
| Track | `0x158048000` | `0x158048000` |
| Item | `0x14b2f9600` | `0x14b2f9600` |
| Take | `0x121672e10` | `0x121672e10` |
| Source | `0x16789e510` | `0x16789e510` |
| **GetMediaSourceNumChannels** | **2** | **1** |
| **GetMediaItemTake_Peaks (any rate)** | **256 peaks** | **0** |
| **PCM_Source_GetPeaks (any rate)** | **256 peaks** | **0** |

## Root Cause

Unknown. The bug is definitively in **REAPER's GetFunc() pathway on ARM64**, not in our calling code:

- **libffi wrapper**: Failed - same result
- **C shim**: Failed - same result
- **PCM_Source_GetPeaks**: Different API, same failure
- **GetMediaSourceNumChannels**: Also returns wrong values (1 instead of 2)

Multiple unrelated APIs fail when called via GetFunc() on ARM64. Lua uses a different internal code path that works correctly.

> **Note**: `starttime` must be PROJECT time (timeline position), not item-relative.

## Solution: Lua Bridge (IMPLEMENTED)

Have Lua fetch peaks (which works), transfer to Zig via binary-packed strings.

### Architecture Overview

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Frontend      │────▶│  Zig Extension   │────▶│   Lua Script    │
│ (viewport zoom) │     │ (tile cache/LOD) │     │ (GetMediaItem-  │
│                 │◀────│                  │◀────│  Take_Peaks)    │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

1. Frontend sends `peaks/updateViewport` when LOD changes
2. Zig calculates which tiles are needed, checks cache
3. For cache misses: Zig sets request params → calls Lua via `Main_OnCommand`
4. Lua fetches peaks via REAPER API → packs as binary → transfers to Zig
5. Zig caches tiles, broadcasts to frontend

### Key Implementation Details

**Zig APIs registered for Lua** (`main.zig` LuaPeakBridge):
- `Reamo_GetPeakRequestValid()` - Check if request pending
- `Reamo_GetPeakRequestTrackIdx()` - Get track index
- `Reamo_GetPeakRequestItemIdx()` - Get item index
- `Reamo_GetPeakRequestStartTime()` - Get start time (project time)
- `Reamo_GetPeakRequestEndTime()` - Get end time
- `Reamo_GetPeakRequestPeakrate()` - Get peakrate
- `Reamo_ReceivePeakData(packed, count)` - Receive binary peak data
- `Reamo_SetPeakRequestComplete(count)` - Signal completion

**Why individual getters instead of packed struct?**
C strings are null-terminated. A packed struct with `track_idx=0` contains null bytes, which truncates the string when passed to Lua. Individual getter functions avoid this issue.

**Vararg wrapper gotchas (ARM64 PAC):**
- Integer args: Use `@truncate(@as(isize, @bitCast(@intFromPtr(arglist[N]))))`
- Double return values: Use static storage, return pointer to real memory (not `@ptrFromInt(bits)` - PAC rejects fake pointers)

**LOD change detection** (`peaks_subscriptions.zig`):
- Track `last_broadcast_lod` per client
- On `updateViewport`: if LOD changed → set `force_broadcast = true`
- Without this, viewport updates wouldn't trigger new tile generation

### Performance (Validated)

Viewport-driven fetching (10-second slice at LOD 6, 256 peaks/sec):

| Step | Time |
|------|------|
| GetMediaItemTake_Peaks | 0.12ms |
| arr.table() | 0.04ms |
| Batched string.pack | 0.43ms |
| Transfer to Zig | 1.57ms |
| **Total** | **~2.2ms** |

Well under the 16.7ms frame budget. Typical full generation cycle: 5-15ms.

### Files Modified

**Zig Extension:**
- `extension/src/main.zig` - LuaPeakBridge with 8 API functions + vararg wrappers
- `extension/src/peaks_generator.zig` - Viewport-based fetching (only fetch tiles in view)
- `extension/src/peaks_subscriptions.zig` - LOD change detection, `last_broadcast_lod` tracking
- `extension/src/peaks_tile.zig` - Epoch computation using source pointer only (not channel count)
- `extension/src/reaper/raw.zig` - `AddRemoveReaScript` binding
- `extension/src/commands/peaks_subs.zig` - Logging for `updateViewport`

**Lua Script:**
- `Scripts/Reamo/reamo_internal_fetch_peaks.lua` - Peak fetching script

**Frontend:**
- `frontend/src/hooks/usePeaksSubscription.ts` - Effect 2 sends `updateViewport` on LOD change
- `frontend/src/core/lod.ts` - `calculateLODFromViewport()` for LOD selection

## LOD System

| LOD | Viewport Duration | Peakrate | Tile Duration |
|-----|-------------------|----------|---------------|
| 0 | > 5hr | 0.0625/s | 4096s |
| 1 | 80min-5hr | 0.25/s | 1024s |
| 2 | 20-80min | 1/s | 256s |
| 3 | 5-20min | 4/s | 64s |
| 4 | 75s-5min | 16/s | 16s |
| 5 | 20-75s | 64/s | 4s |
| 6 | < 20s | 256/s | 1s |

All LODs use 256 peaks per tile. LOD selection based on viewport duration ensures appropriate detail at each zoom level.

## Cache System

- Tiles cached by `(take_guid, epoch, lod, tile_index)`
- Epoch = hash of source pointer (NOT channel count - unreliable on ARM64)
- Source replaced → new epoch → old tiles orphaned automatically
- Cache survives pan/zoom at same LOD (100% hit rate when panning)

## Lessons Learned

1. **ARM64 PAC is strict**: Can't create fake pointers from arbitrary bits. Use real memory addresses.
2. **C strings truncate on null**: Don't pack structs with potential zero bytes for Lua interop.
3. **Channel count unreliable**: `GetMediaSourceNumChannels` returns inconsistent values via GetFunc on ARM64.
4. **LOD changes need explicit triggers**: Viewport updates alone don't cause broadcasts - must detect LOD change and set force flag.
5. **Viewport-based fetching critical**: Fetching entire item at high peakrates causes 100K+ peak requests. Only fetch visible tiles.

## Known Issues

- `ShowConsoleMsg` opens console window if not already open - need silent logging option (write to file or check if console is open first)

## Fixes Applied

- **Section source handling**: `GetMediaItemTake_Source` returns wrapper sources for items with take offsets. Fixed by traversing to root source via `GetMediaSourceParent` loop.
- **Channel count bypass**: Always request 2 channels instead of trusting `GetMediaSourceNumChannels` (unreliable even in Lua).
- **Peak building retry**: If `GetMediaItemTake_Peaks` returns 0, try `PCM_Source_BuildPeaks` (fast mode first, then full) and retry.

## Integration Checklist

**Zig APIs:**
- [x] `Reamo_ReceivePeakData` API
- [x] `Reamo_GetPeakCount` API
- [x] `Reamo_ClearPeakBuffer` API
- [x] `Reamo_GetPeakRequestValid` API
- [x] `Reamo_GetPeakRequestTrackIdx` API
- [x] `Reamo_GetPeakRequestItemIdx` API
- [x] `Reamo_GetPeakRequestStartTime` API
- [x] `Reamo_GetPeakRequestEndTime` API
- [x] `Reamo_GetPeakRequestPeakrate` API
- [x] `Reamo_SetPeakRequestComplete` callback

**Lua Script:**
- [x] Batched `string.pack` optimization (BATCH=1000)
- [x] Create `Scripts/Reamo/reamo_internal_fetch_peaks.lua`
- [x] Debug logging for 0-peak cases
- [ ] Add script to installer
- [ ] Test graceful degradation when script missing

**Integration:**
- [x] Wire into `peaks_generator.zig`
- [x] Viewport-based fetching (only tiles in view)
- [x] LOD change detection triggers broadcast
- [ ] Validate take pointer before reading buffer

**Validation:**
- [x] Test stereo items - renders as split L/R lanes
- [x] Test long items (>1 hour) - works with 69-minute project
- [x] Validate on ARM64 macOS at LOD levels 2-6
- [ ] Profile memory usage
- [ ] Test LODs 0-1 (very zoomed out)

## Alternatives Considered

- **libffi wrapper**: Tried using libffi to handle ABI correctly. **Failed** - same result as direct call.
- **C shim**: Tried wrapping in plain C function. **Failed** - same result.
- **PCM_Source_GetPeaks**: Tried alternative API that operates on source instead of take. **Failed** - same GetFunc bug affects it.
- **AudioAccessor**: Read raw samples, compute peaks manually. Works but slower.
- **Direct .reapeaks**: Read mipmap files directly. Complex format parsing.
