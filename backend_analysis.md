# Backend Codebase Analysis

This document provides a comprehensive audit of the Zig backend extension codebase, identifying technical debt, cleanup opportunities, workarounds, and architectural concerns. Since this application is pre-release with no existing clients, now is the optimal time for cleanup.

## Table of Contents

1. [Workarounds and REAPER API Quirks](#1-workarounds-and-reaper-api-quirks)
2. [Legacy/Backward Compatibility Code](#2-legacybackward-compatibility-code)
3. [~~Duplicate Command Registry System~~](#3-duplicate-command-registry-system) *(FIXED)*
4. [~~Global State Pattern~~](#4-global-state-pattern) *(FIXED)*
5. [~~Duplicated MAX_* Constants~~](#5-duplicated-max_-constants) *(FIXED)*
6. [Incomplete Implementations](#6-incomplete-implementations)
7. [~~Unicode Support Limitations~~](#7-unicode-support-limitations) *(FIXED)*
8. [Silent Error Handling Patterns](#8-silent-error-handling-patterns)
9. [Static Buffer Patterns](#9-static-buffer-patterns)
10. [Debug Code in Production](#10-debug-code-in-production)
11. [Cleanup Recommendations by Priority](#11-cleanup-recommendations-by-priority)

---

## 1. Workarounds and REAPER API Quirks

### Color Reset Workaround
**Files:** [commands/markers.zig:83](extension/src/commands/markers.zig#L83), [commands/regions.zig:232](extension/src/commands/regions.zig#L232)

REAPER's `SetProjectMarker4` API treats color=0 as "don't modify color" rather than "reset to default". The workaround is to delete and recreate the marker/region with the same ID:

```zig
// Workaround: delete and recreate marker with same ID
if (reset_to_default) {
    _ = api.deleteMarker(id);
    _ = api.addMarkerWithId(pos, name, 0, id);
}
```

**Impact:** Low - this is a necessary workaround for REAPER's API behavior.

**Recommendation:** Document in API.md that color=0 means "reset to default" and note the REAPER limitation.

---

### GetMediaSourceNumChannels Bug
**File:** [commands/items.zig:208](extension/src/commands/items.zig#L208)

```zig
// GetMediaSourceNumChannels is broken (returns 1 for stereo files - REAPER bug)
```

The code works around this by always requesting stereo from AudioAccessor and detecting mono/stereo by comparing L/R channel data.

**Impact:** None - workaround is clean and well-documented in DEVELOPMENT.md.

---

## 2. Legacy/Backward Compatibility Code

### ~~Deprecated tracks.State.pollInto~~ *(FIXED)*

**Status:** Removed in cleanup commit.

The deprecated `pollInto` method was removed entirely from [tracks.zig](extension/src/tracks.zig). Since there are no existing clients, backward compatibility was not required.

---

### Legacy tiered_state.init
**File:** [tiered_state.zig:380-383](extension/src/tiered_state.zig#L380-L383)

```zig
/// Legacy init - uses default sizes for backwards compatibility
pub fn init(backing: Allocator) !Self {
    return initWithDefaults(backing);
}
```

**Impact:** Low - wrapper function that could be simplified.

**Recommendation:** Rename `initWithDefaults` to `init` and remove the legacy wrapper.

---

### ~~Legacy Command Types~~ *(FIXED)*

**Status:** Removed in cleanup commit.

The `Entry` struct and `Handler` type alias were removed from [commands/mod.zig](extension/src/commands/mod.zig). These existed only for legacy test support and added confusion about how dispatch works.

---

### Fallback Full Polling Path
**File:** [main.zig:607](extension/src/main.zig#L607)

```zig
// Track subscriptions not initialized - fall back to full polling (legacy/startup)
```

**Impact:** Low - this is a reasonable fallback for startup but could be simplified once subscriptions are stable.

---

## 3. ~~Duplicate Command Registry System~~ *(FIXED)*

**Status:** Fully resolved in cleanup commit.

The legacy `handlers` arrays were removed from all 21 command modules. The codebase now uses only the comptime tuple registry in [commands/registry.zig](extension/src/commands/registry.zig).

**Changes made:**
- Removed `pub const handlers` arrays from: transport.zig, markers.zig, regions.zig, items.zig, takes.zig, time_sel.zig, repeat.zig, tracks.zig, tempo.zig, timesig.zig, metronome.zig, master.zig, extstate.zig, undo.zig, actions.zig, gesture.zig, toggle_state.zig, midi.zig, project_notes.zig, preferences.zig, debug.zig
- Removed the `registry` concatenation from mod.zig
- Updated the test in mod.zig to use `comptime_registry.all` with compile-time verification
- Removed `Entry` and `Handler` type aliases

**Result:** ~320 net lines removed. Commands now only need to be added in one place (registry.zig).

---

## 4. ~~Global State Pattern~~ *(FIXED)*

**Status:** Consolidated into `CommandContext` struct in cleanup commit.

The scattered globals in command modules have been consolidated into a single `CommandContext` struct in [commands/mod.zig:49-58](extension/src/commands/mod.zig#L49-L58):

```zig
pub const CommandContext = struct {
    toggle_subs: ?*toggle_subscriptions.ToggleSubscriptions = null,
    notes_subs: ?*project_notes.NotesSubscriptions = null,
    guid_cache: ?*guid_cache.GuidCache = null,
    track_subs: ?*track_subscriptions.TrackSubscriptions = null,
    tiered: ?*tiered_state.TieredArenas = null,
};

/// Global command context - initialized by main.zig
pub var g_ctx: CommandContext = .{};
```

**Changes made:**
- Created `CommandContext` struct in mod.zig
- Removed individual globals from: toggle_state.zig, project_notes.zig, tracks.zig, debug.zig, track_subs.zig
- Updated all handlers to use `mod.g_ctx.*` instead of local globals
- Updated main.zig to set `commands.g_ctx.*` fields during initialization/cleanup
- Removed unused imports (`track_subs_cmd`, `tracks_cmd`) from main.zig

**Note:** The core globals in main.zig (g_api, g_allocator, g_shared_state, etc.) remain as-is since they are needed for the polling loop and lifecycle management.

---

## 5. ~~Duplicated MAX_* Constants~~ *(FIXED)*

**Status:** Consolidated into [constants.zig](extension/src/constants.zig) in cleanup commit.

A new shared constants file was created with all MAX_* constants:

```zig
// constants.zig
pub const MAX_NAME_LEN: usize = 128;
pub const MAX_FX_NAME_LEN: usize = 128;
pub const MAX_SEND_NAME_LEN: usize = 128;
pub const MAX_GUID_LEN: usize = 40;
pub const MAX_TRACKS: usize = 128;
pub const MAX_FX_PER_TRACK: usize = 64;
pub const MAX_SENDS_PER_TRACK: usize = 16;
pub const MAX_ITEMS: usize = 512;
pub const MAX_TAKES_PER_ITEM: usize = 8;
pub const MAX_MARKERS: usize = 256;
pub const MAX_REGIONS: usize = 256;
pub const MAX_SUBSCRIPTION_CLIENTS: usize = 16;
pub const MAX_TRACKS_PER_CLIENT: usize = 64;
pub const MAX_GUIDS_PER_CLIENT: usize = 64;
pub const MAX_COMMAND_IDS_PER_CLIENT: usize = 256;
```

**Files updated:**
- tracks.zig, items.zig, markers.zig, fx.zig, sends.zig, playlist.zig - use `constants.MAX_*`
- track_skeleton.zig, track_subscriptions.zig, toggle_subscriptions.zig - use `constants.MAX_*`
- All modules re-export constants for backward compatibility

---

## 6. Incomplete Implementations

### Mock deleteItem Stub
**File:** [reaper/mock/tracks.zig:484](extension/src/reaper/mock/tracks.zig#L484)

```zig
pub fn deleteItem(self: anytype, track: *anyopaque, item: *anyopaque) bool {
    self.recordCall(.deleteItem);
    _ = track;
    _ = item;
    // In real mock we'd remove from array, for now just acknowledge
    return true;
}
```

**Impact:** Low - affects test fidelity but not production.

---

### Send Default Values
**File:** [sends.zig:119](extension/src/sends.zig#L119)

```zig
// For now, we leave them at defaults (can be enhanced later)
```

---

### Toggle Subscription Limit
**File:** [toggle_subscriptions.zig:70](extension/src/toggle_subscriptions.zig#L70)

```zig
// For now, just fail - we'll clean up on disconnect
```

---

### Track Subscription Test
**File:** [commands/track_subs.zig:118](extension/src/commands/track_subs.zig#L118)

```zig
// For now, just verify the module compiles
```

---

## 7. ~~Unicode Support Limitations~~ *(FIXED)*

**Status:** Fixed in cleanup commit.

The JSON unescaping in [protocol.zig:160-193](extension/src/protocol.zig#L160-L193) now properly encodes Unicode codepoints to UTF-8:

```zig
'u' => {
    // \uXXXX - decode to UTF-8
    if (codepoint < 0x80) {
        out_buf[out_idx] = @intCast(codepoint);
        out_idx += 1;
    } else if (codepoint < 0x800) {
        // 2-byte UTF-8
        if (out_idx + 2 > out_buf.len) break;
        out_buf[out_idx] = @intCast(0xC0 | (codepoint >> 6));
        out_buf[out_idx + 1] = @intCast(0x80 | (codepoint & 0x3F));
        out_idx += 2;
    } else {
        // 3-byte UTF-8
        if (out_idx + 3 > out_buf.len) break;
        out_buf[out_idx] = @intCast(0xE0 | (codepoint >> 12));
        out_buf[out_idx + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        out_buf[out_idx + 2] = @intCast(0x80 | (codepoint & 0x3F));
        out_idx += 3;
    }
    i += 6;
},
```

Project names, track names, and marker names with non-ASCII characters are now handled correctly.

---

## 8. Silent Error Handling Patterns *(PARTIALLY FIXED)*

**Status:** Full audit completed. See **[error_handling.md](error_handling.md)** for comprehensive checklist.

**Summary:** 195 instances identified across 8 categories:

| Category | Count | Priority | Status |
|----------|-------|----------|--------|
| Subscription slot allocation | 3 | HIGH | **FIXED** |
| ResponseWriter methods | 5 | MEDIUM | **FIXED** |
| Event serialization (toJson) | ~150 | MEDIUM | See note* |
| Command handler responses | ~20 | MEDIUM | **FIXED** |
| WebSocket server | 2 | MEDIUM | **FIXED** |
| Playlist persistence | 3 | LOW | **FIXED** |
| Protocol JSON helpers | 7 | LOW | ACCEPTABLE |
| Debug/logging code | 5 | N/A | ACCEPTABLE |

*Event serialization: Most `toJson` methods migrated to `toJsonAlloc` using scratch arena (see Section 9). Buffer overflow is no longer a concern for dynamically-sized JSON. Remaining fixed-buffer methods have logging added.

**Completed fixes:**
- Subscription failures now log the actual error before returning `TooManyClients`
- ResponseWriter methods log buffer overflow with cmd_id and payload size
- Command handlers log format failures before returning
- WebSocket server logs frame/header serialization failures
- Playlist persistence logs save/load errors
- DEVELOPMENT.md updated with "never use silent catch" guideline (#18)

---

## 9. Static Buffer Patterns *(MOSTLY MIGRATED)*

**Status:** Production JSON serialization migrated to scratch arena. Only test helpers remain with static buffers.

### JSON Serialization - Migrated to Scratch Arena

All production `toJson` call sites now use `toJsonAlloc` with the scratch arena allocator:

| Module | Method | Status |
|--------|--------|--------|
| transport.zig | `toJsonAlloc` | ✓ Already dynamic |
| project.zig | `toJsonAlloc` | ✓ Already dynamic |
| markers.zig | `toJsonAlloc` | ✓ Already dynamic |
| items.zig | `toJsonAlloc` | ✓ Already dynamic |
| fx.zig | `toJsonAlloc` | ✓ Already dynamic |
| sends.zig | `toJsonAlloc` | ✓ Already dynamic |
| playlist.zig | `toJsonAlloc` | ✓ Already dynamic |
| tempomap.zig | `toJsonAlloc` | ✓ Already dynamic |
| tracks.zig | `toJsonWithTotalAlloc`, `toJsonEventAlloc` | **FIXED** |
| track_skeleton.zig | `toJsonAlloc` | **FIXED** |
| toggle_subscriptions.zig | `changesToJsonAlloc` | **FIXED** |
| errors.zig | `toJsonAlloc` | **FIXED** |

**Scratch arena sizing** (tiered_state.zig):
```zig
const scratch_raw = @max(
    counts.tracks * 600,   // ~600 bytes per track JSON (with GUID)
    counts.items * 256,    // ~256 bytes per item JSON
) + 128 * 1024;            // Base for skeleton, metering, toggles, errors
```

This supports extreme projects (3000 tracks, 10000 items) without fixed buffer limits.

### Remaining Static Buffers (Test-Only)

These are correctly marked as test-only and don't affect production:

- items.zig `pollStatic` - test convenience wrapper
- markers.zig `pollStatic` - test convenience wrapper
- tracks.zig test helpers - static buffers for mock tracks

**Recommendation:** Low priority - consider moving to `test_utils.zig` eventually.

---

## 10. ~~Debug Code in Production~~ *(FIXED)*

### ~~DEBUG_LOGGING Always True~~ *(FIXED)*
**File:** [reaper/raw.zig:18](extension/src/reaper/raw.zig#L18)

Now set to `false` for release builds.

---

### ~~Debug File Logging~~ *(FIXED)*

Removed `logTickToFile` and associated code from main.zig.

---

## 11. Cleanup Recommendations by Priority

### High Priority ~~(Should fix before release)~~ *(ALL FIXED)*

| Item | Status | Files Changed |
|------|--------|---------------|
| ~~Remove duplicate command registry~~ | **FIXED** | 21 command modules, mod.zig |
| ~~Fix Unicode support~~ | **FIXED** | protocol.zig |
| ~~Remove deprecated `pollInto`~~ | **FIXED** | tracks.zig |

### Medium Priority

| Item | Status | Files | Effort | Impact |
|------|--------|-------|--------|--------|
| ~~Consolidate globals into Context~~ | **FIXED** | main.zig, commands/*.zig | High | Improves testability, clearer dependencies |
| ~~Consolidate MAX_* constants~~ | **FIXED** | constants.zig + 9 modules | Low | Prevents divergence |
| ~~Add logging to silent error paths~~ | **FIXED** | subscriptions, commands, ws_server, playlist | Low | Improves debuggability |
| ~~Migrate toJson to scratch arena~~ | **FIXED** | tracks, track_skeleton, toggle_subs, main | Medium | Supports extreme projects |
| ~~Set DEBUG_LOGGING=false~~ | **FIXED** | raw.zig | Trivial | Cleaner console output |

### Low Priority (Nice to have)

| Item | Status | Files | Effort | Impact |
|------|--------|-------|--------|--------|
| ~~Implement mock deleteItem properly~~ | **FIXED** | mock/tracks.zig | Low | Better test fidelity |
| Move static buffers to test_utils | TODO | items.zig, markers.zig | Low | Cleaner separation |
| ~~Document REAPER workarounds in API.md~~ | **FIXED** | API.md | Low | Better documentation |
| ~~Remove legacy tiered_state.init wrapper~~ | **FIXED** | tiered_state.zig | Trivial | Cleaner API |

---

## Summary

The backend codebase is generally well-structured with good patterns (comptime dispatch, FFI validation layer, tiered arena allocation).

### Completed Cleanup

The following major cleanup items have been completed:

1. **Duplicate command registry** - Removed legacy `handlers` arrays from all 21 command modules. ~320 lines removed.
2. **Unicode handling** - Proper UTF-8 encoding for \uXXXX escape sequences.
3. **Legacy APIs** - Removed deprecated `pollInto` from tracks.zig, legacy `tiered_state.init` wrapper.
4. **MAX_* constants** - Consolidated into shared `constants.zig`.
5. **Global state** - Command handler globals consolidated into `CommandContext` struct.
6. **Silent error handling** - Added logging to subscription, response, command, WebSocket, and playlist error paths.
7. **JSON buffer sizing** - Migrated all production `toJson` to `toJsonAlloc` with dynamic scratch arena sizing. Supports extreme projects (3000 tracks, 10000 items).
8. **Debug code** - Set `DEBUG_LOGGING=false`, removed playlist tick file logging.
9. **Mock implementation** - Proper `deleteItem` implementation in mock/tracks.zig.
10. **Documentation** - REAPER API quirks documented in API.md.

### Remaining Items

- Move static buffers to test_utils (low priority)

Since this is a pre-release application, the codebase is now in excellent shape for release.
