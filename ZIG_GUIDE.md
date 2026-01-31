# Zig Extension Guide

Concise guide for writing safe, correct Zig code in the REAmo REAPER extension. Read this before implementing new features.

**For comprehensive details, see:** `DEVELOPMENT.md`

---

## Table of Contents

1. [Memory & Stack Safety](#1-memory--stack-safety) — Scratch arena, no large stack buffers
2. [FFI/ABI Correctness](#2-ffiabi-correctness) — Sentinel slices, @ptrCast pitfalls
3. [Error Handling](#3-error-handling-no-silent-failures) — Log everything, never swallow errors
4. [Command Handler Checklist](#4-command-handler-checklist) — Validation, undo blocks, return values
5. [Backend Architecture](#5-backend-architecture) — raw/real/mock pattern
6. [Quick Reference](#6-quick-reference) — Do/Don't table, common patterns
7. [REAPER API Gotchas](#7-reaper-api-gotchas) — Master track, colors, pointer validation
8. [Numeric Safety](#8-numeric-safety) — Float-to-int, precision, linear vs dB
9. [Threading Model](#9-threading-model) — Main thread only, mutex queue
10. [Response Buffer Sizes](#10-response-buffer-sizes) — successLargePayload, dynamic JSON
11. [Undo Block Rules](#11-undo-block-rules) — Naming, no nesting
12. [Action ID Stability](#12-action-id-stability) — Native vs SWS storage
13. [Testing](#13-testing) — **INVOKE `/reamo-ws` SKILL** for live testing, mock patterns

---

## 1. Memory & Stack Safety

### The Problem

REAPER's timer callbacks run during modal dialogs (e.g., "missing media" prompts) with deeply nested call stacks (~45+ frames). Zig allocates ALL local variables at function entry. A 64KB buffer exhausts remaining stack space before any code runs.

**This caused production crashes.**

### The Rule

**Never stack-allocate buffers >1KB in command handlers or any code called from timer callbacks.**

### The Pattern: Scratch Arena

Command handlers have access to a scratch arena that resets every frame. Use it for temporary buffers:

```zig
// BAD: Stack allocation - will crash under deep call stacks
var buf: [65536]u8 = undefined;
const data = api.getSomeData(&buf);

// GOOD: Scratch arena - safe, O(1) allocation, no free needed
const tiered = mod.g_ctx.tiered orelse {
    response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
    return;
};
const scratch = tiered.scratchAllocator();
const buf = scratch.alloc(u8, 65536) catch {
    response.err("ALLOC_FAILED", "Failed to allocate buffer");
    return;
};
const data = api.getSomeData(buf);
```

### When Scratch Arena Isn't Available

For code outside command handlers, use heap allocation:

```zig
const allocator = std.heap.c_allocator;
const buf = allocator.alloc(u8, 65536) catch {
    // Handle error
    return;
};
defer allocator.free(buf);
```

Heap allocation is safe in timer callbacks (main thread). It's ~100-500ns for 64KB — negligible.

---

## 2. FFI/ABI Correctness

### Sentinel-Terminated Slices for C Strings

REAPER's C API expects null-terminated strings (`const char*`). Zig's `[:0]const u8` type enforces this at compile time.

```zig
// BAD: Regular slice - no null terminator guarantee
fn setData(data: []const u8) { ... }

// GOOD: Sentinel slice - type system enforces null terminator
fn setData(data: [:0]const u8) {
    const c_ptr = data.ptr;  // Safe coercion to [*:0]const u8
    reaper_c_function(c_ptr);
}
```

### Creating Sentinel Slices

When you have a buffer you've written to:

```zig
const buf = scratch.alloc(u8, size + 1) catch { ... };  // +1 for null
// ... write data, track length in `offset` ...
buf[offset] = 0;  // Add null terminator
const sentinel: [:0]const u8 = buf[0..offset :0];  // Runtime assertion
```

The `:0` in `buf[0..offset :0]` asserts the sentinel exists — Zig will panic if `buf[offset] != 0`.

### @ptrCast Pitfalls

**The crash:** Passing `@ptrCast(&buf)` when the C function expects `[*:0]const u8`.

```zig
var param_buf: [32]u8 = undefined;
@memcpy(param_buf[0..len], param[0..len]);
param_buf[len] = 0;

// BAD: @ptrCast(&param_buf) is *[32]u8, not [*:0]const u8
const success = c_func(track, @ptrCast(&param_buf), ...);  // ABI mismatch!

// GOOD: Sentinel slice coerces correctly
const param_ptr: [*:0]const u8 = param_buf[0..len :0];
const success = c_func(track, param_ptr, ...);
```

### raw.zig vs real.zig Boundary

| Layer | Responsibility |
|-------|----------------|
| `raw.zig` | Pure C bindings. Returns exactly what REAPER returns. No allocation. |
| `real.zig` | Validation layer. Wraps raw with `ffi.safeFloatToInt()`, NaN/Inf checks. |

**Principle:** Push allocation to callers (command handlers). Keep FFI layers allocation-free.

---

## 3. Error Handling: No Silent Failures

### The Problem

Silent `catch return;` makes debugging impossible. Frontend times out, no logs, no clue what happened.

### The Rule

**Never swallow errors silently. Always log or return an error response.**

```zig
// BAD: Silent failure - impossible to debug
const json = std.fmt.bufPrint(&buf, "...", .{...}) catch return;

// GOOD: Log the failure
const json = std.fmt.bufPrint(&buf, "...", .{...}) catch {
    logging.warn("handleFoo: buffer overflow formatting response", .{});
    return;
};

// BETTER: Return error to client
const json = std.fmt.bufPrint(&buf, "...", .{...}) catch {
    response.err("BUFFER_OVERFLOW", "Response too large");
    return;
};
```

### Parse Failures

When parsing user input or REAPER state chunks:

```zig
// BAD: Silent default
const value = std.fmt.parseInt(i32, str, 10) catch 0;

// GOOD: Log unexpected parse failures
const value = std.fmt.parseInt(i32, str, 10) catch |err| blk: {
    logging.warn("Failed to parse value: {}", .{err});
    break :blk 0;  // Default after logging
};
```

### Logging Levels

| Level | When to Use |
|-------|-------------|
| `logging.err()` | Should never happen — indicates a bug |
| `logging.warn()` | Unexpected but recoverable (buffer overflow with real data) |
| `logging.debug()` | Expected in edge cases, verbose |

---

## 4. Command Handler Checklist

When adding a new command handler:

### 1. Register in registry.zig

```zig
// extension/src/commands/registry.zig
pub const all = .{
    // ... existing handlers ...
    .{ "myFeature/doThing", my_feature.handleDoThing },
};
```

**Forgetting this = command silently not found.**

### 2. Validate All Inputs

```zig
pub fn handleDoThing(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Required parameters
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_PARAM", "trackIdx is required");
        return;
    };

    // Time/position validation (rejects negative, NaN, Inf)
    const position = mod.validatePosition(cmd.getFloat("position")) orelse {
        response.err("INVALID_POSITION", "position must be non-negative");
        return;
    };

    // Track resolution (handles both trackIdx and trackGuid)
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
}
```

### 3. Guard Against Division by Zero

```zig
const count = api.getItemCount();
if (count <= 0) {
    response.err("NO_ITEMS", "Track has no items");
    return;
}
const ratio = 1.0 / @as(f64, @floatFromInt(count));  // Safe
```

### 4. Normalize User Input Ranges

Users can drag right-to-left, resulting in `startTime > endTime`:

```zig
const raw_start = cmd.getFloat("startTime") orelse { ... };
const raw_end = cmd.getFloat("endTime") orelse { ... };

// Normalize: swap if needed
const start_time = @min(raw_start, raw_end);
const end_time = @max(raw_start, raw_end);

if (start_time == end_time) {
    response.err("INVALID_RANGE", "Start and end cannot be equal");
    return;
}
```

### 5. Use trackGuid for Gestures

During a fader drag, user might reorder tracks. If frontend sends `trackIdx`, gesture end affects the wrong track.

```zig
// GOOD: resolveTrack handles both trackIdx and trackGuid
const resolution = tracks.resolveTrack(api, cmd) orelse {
    response.err("NOT_FOUND", "Track not found");
    return;
};
// resolution.idx is the CURRENT index, even if track moved
```

Frontend sends `trackGuid` when available (preferred), falls back to `trackIdx`.

### 6. Use Undo Blocks for State Changes

```zig
api.undoBeginBlock();

// ... make changes ...

if (success) {
    api.undoEndBlock("REAmo: Did the thing");
    response.success(null);
} else {
    api.undoEndBlock("REAmo: Did the thing (failed)");
    response.err("FAILED", "Operation failed");
}
```

### 7. Check Return Values

```zig
// BAD: Ignoring failure
api.setTrackVolume(track, volume);

// GOOD: Handle failure
if (!api.setTrackVolume(track, volume)) {
    response.err("SET_FAILED", "Failed to set volume");
    return;
}
```

---

## 5. Backend Architecture

### anytype for Testability

All handlers accept `anytype` for the API parameter, enabling mock injection:

```zig
pub fn handlePlay(api: anytype, cmd: CommandMessage, response: *ResponseWriter) void {
    api.runCommand(Command.PLAY);
    response.success(null);
}
```

Both `*RealBackend` and `*MockBackend` satisfy the duck-typed interface.

### Adding New Backend Methods

When a handler needs a new REAPER API method:

1. **raw.zig** — Add pure C binding
   ```zig
   pub fn newMethod(self: *const Api, param: c_int) f64 {
       const f = self.someReaperFunction orelse return 0;
       return f(param);
   }
   ```

2. **real.zig** — Add validated wrapper
   ```zig
   pub fn newMethod(self: *const RealBackend, param: c_int) ffi.FFIError!i32 {
       return ffi.safeFloatToInt(i32, self.inner.newMethod(param));
   }
   ```

3. **mock/relevant_file.zig** — Add mock implementation
   ```zig
   pub fn newMethod(self: *MockTracks, param: c_int) ffi.FFIError!i32 {
       self.recordCall(.newMethod);
       return self.new_method_result;
   }
   ```

4. **backend.zig** — Add to `validateBackend` required methods
   ```zig
   const required_methods = [_][]const u8{
       // ... existing ...
       "newMethod",
   };
   ```

**The `validateBackend()` check catches missing methods at compile time.**

### Mock Method Recording

Mocks track which methods were called for test assertions:

```zig
test "handler calls correct API method" {
    var mock = MockBackend{};
    var response = TestResponseWriter{};

    myHandler(&mock, cmd, &response);

    try testing.expect(mock.wasMethodCalled(.newMethod));
}
```

---

## 6. Quick Reference

### Do / Don't

| Don't | Do |
|-------|-----|
| `var buf: [65536]u8 = undefined;` | `scratch.alloc(u8, 65536)` |
| `catch return;` | `catch { logging.warn(...); return; }` |
| `@ptrCast(&buf)` for C strings | `buf[0..len :0]` sentinel slice |
| `@intFromFloat(api.getValue())` | `ffi.safeFloatToInt(i32, val)` |
| `value = parse(...) catch 0;` | `value = parse(...) catch \|err\| { log; 0 };` |
| Forget registry.zig | Always add new handlers to registry |
| `1.0 / count` without check | Guard `count <= 0` first |
| Assume start < end | `@min/@max` to normalize |
| `response.success(large_data)` | `response.successLargePayload(large_data)` |
| `api.undoEndBlock("Did thing")` | `api.undoEndBlock("REAmo: Did thing")` |
| `GetTrack(proj, 0)` for master | `getTrackByUnifiedIdx(0)` |
| `GetMediaTrackInfo_Value(master, "B_MUTE")` | `getMasterMuteFlags() & 1` |

### Common Patterns

```zig
// Get scratch allocator
const scratch = mod.g_ctx.tiered.?.scratchAllocator();

// Resolve track (handles trackIdx or trackGuid)
const resolution = tracks.resolveTrack(api, cmd) orelse { ... };

// Validate position (rejects negative, NaN, Inf)
const pos = mod.validatePosition(cmd.getFloat("position")) orelse { ... };

// Safe float to int
const n: i32 = ffi.safeFloatToInt(i32, api.getValue()) catch 0;

// Sentinel slice from buffer
buf[len] = 0;
const sentinel: [:0]const u8 = buf[0..len :0];
```

### Files to Modify When Adding...

| Adding | Files |
|--------|-------|
| New command | handler file + `registry.zig` |
| New REAPER API | `raw.zig` + `real.zig` + `mock/*.zig` + `backend.zig` |
| New subscription | `*_subscriptions.zig` + `main.zig` (init/cleanup) |
| New state field | state module + JSON serialization + `API.md` |

---

## 7. REAPER API Gotchas

### Track Indexing: The Master Track Trap

REAPER's C API has different indexing than our WebSocket protocol:

| Context | idx=0 | idx=1+ |
|---------|-------|--------|
| **Our WebSocket API** | Master track | User tracks |
| **REAPER's `GetTrack(proj, 0)`** | First USER track | Second user track... |

```zig
// BAD: Assumes REAPER's indexing matches ours
const track = api.getTrack(project, track_idx);  // Wrong for master!

// GOOD: Use unified index wrapper
const track = api.getTrackByUnifiedIdx(track_idx) orelse { ... };
```

`CountTracks()` returns **user count only** — excludes master.

### Master Track Mute/Solo: Raw API Fails

`GetMediaTrackInfo_Value(master, "B_MUTE")` and `"I_SOLO"` return **stale/incorrect values** on master track.

```zig
// BAD: Unreliable for master
const muted = api.getTrackMuted(master_track);

// GOOD: Use dedicated API
const flags = api.getMasterMuteFlags();  // Returns bitmask
const is_muted = (flags & 1) != 0;
const is_soloed = (flags & 2) != 0;

// GOOD: For writing, use CSurf API
api.csurfSetMute(track, mute, true);   // NOT SetMediaTrackInfo_Value
api.csurfSetSolo(track, solo, true);
```

### Custom Colors: Hidden Bit Flag

`I_CUSTOMCOLOR` has bit 24 (`0x01000000`) as an "enabled" flag.

```zig
const raw = api.getTrackColor(track);
const CUSTOM_COLOR_FLAG: c_int = 0x01000000;
if ((raw & CUSTOM_COLOR_FLAG) == 0) {
    return 0;  // NO custom color - theme default, NOT black
}
return raw;  // HAS custom color
```

**0 does NOT mean black** — it means "use theme default."

### Pointer Validation

REAPER pointers become invalid when user deletes tracks/items mid-operation.

```zig
// In polling loops
const track = api.getTrackByUnifiedIdx(idx) orelse continue;
if (!api.validateTrackPtr(track)) continue;  // Track was deleted

// In command handlers
const track = api.getTrackByUnifiedIdx(track_idx) orelse {
    response.err("NOT_FOUND", "Track not found");
    return;
};
```

**Between `SetTrackListChange` and rebuild, track pointers are stale.** Callbacks check `reverse_map_valid` and bail early.

---

## 8. Numeric Safety

### Float-to-Int: Always Validate

`@intFromFloat` panics on NaN, Inf, or out-of-range values. REAPER APIs can return garbage.

```zig
// BAD: Will panic on corrupt data
const x = @as(i32, @intFromFloat(api.getValue()));

// GOOD: Validated conversion
const x = ffi.safeFloatToInt(i32, api.getValue()) catch 0;

// For display values (beats, ticks) - round first
const tick = ffi.roundFloatToInt(i32, api.getTick()) catch 0;
```

### Precision Loss with Modulo

Float modulo accumulates error. Scale to integer first.

```zig
// BAD: @mod(6.76, 1.0) returns 0.7599999998
const frac = @mod(beat_position, 1.0);

// GOOD: Scale to ticks (integer), then modulo
const ticks_per_beat: i32 = 960;
const total_ticks = @as(i64, @intFromFloat(beat_position * @as(f64, @floatFromInt(ticks_per_beat))));
const tick_in_beat = @mod(total_ticks, ticks_per_beat);
```

### Linear vs dB

Meter values from REAPER are **linear amplitude** (1.0 = 0dB), not dB.

```zig
// Convert for display
const db = volumeToDb(linear_value);  // Use utility function
```

---

## 9. Threading Model

### The Rule

**All REAPER API calls MUST happen on the main thread.**

```
Main Thread (REAPER context)          WebSocket Thread
├─ Timer callback                     ├─ server.listen()
│  └─ Poll REAPER state               └─ Handler callbacks
│  └─ Process command queue              (clientMessage, close)
│  └─ Execute REAPER API
└─ Shared State (Mutex-protected)
   ├─ Command queue
   └─ Connected clients
```

### The Pattern

1. WebSocket thread receives command → Push to mutex-protected queue
2. Timer callback (main thread) dequeues and processes
3. Execute REAPER API calls from main thread only

**Thread-safe WebSocket APIs:** Only `conn.write()` and `server.stop()`.

---

## 10. Response Buffer Sizes

### The 512-Byte Trap

`ResponseWriter.success()` uses a 512-byte buffer. Large payloads fail silently.

```zig
// BAD: Silent failure for large payloads
response.success(large_json_string);  // Silently truncated

// GOOD: Use large payload variant
response.successLargePayload(large_json_string);
```

**When to use `successLargePayload()`:**
- Project notes (user content)
- Item peaks
- State chunks
- Anything potentially >500 bytes

### JSON Serialization for Large Data

Don't use fixed buffers for variable-size data.

```zig
// BAD: Fixed buffer fails on 3000+ tracks
var buf: [65536]u8 = undefined;
if (state.toJson(&buf)) |json| { ... }

// GOOD: Dynamic allocation
const scratch = tiered.scratchAllocator();
if (state.toJsonAlloc(scratch)) |json| { ... } else |_| {}
```

---

## 11. Undo Block Rules

### Naming Convention

All undo blocks **MUST** be prefixed with `"REAmo: "`:

```zig
api.undoBeginBlock();
api.undoEndBlock("REAmo: Adjust time signature");  // Prefix required
```

This makes debugging REAPER's undo history possible.

### No Nested Undo Blocks

REAPER doesn't support nested undo blocks. Calling `undoBeginBlock()` twice before `undoEndBlock()` **corrupts REAPER's undo state**.

For concurrent gestures (multiple hw outputs being dragged), use reference counting:

```zig
// Track active gestures
if (is_new_gesture) {
    if (gestures.beginHwUndoBlock()) {  // Returns true if count was 0
        api.undoBeginBlock();
    }
}

// On gesture end
if (gestures.endHwUndoBlock()) {  // Returns true if count becomes 0
    api.undoEndBlock("REAmo: Adjust audio hardware outputs");
}
```

---

## 12. Action ID Stability

REAPER action IDs have different stability guarantees:

| Action Type | Numeric ID Stable? | Storage Strategy |
|-------------|-------------------|------------------|
| Native REAPER | ✅ Yes | Store `"40001"` |
| SWS Extension | ❌ No | Store `"_SWS_SAVESEL"` |
| ReaScripts | ❌ No | Store `"_RS7f8a2b..."` |
| Custom Actions | ❌ No | Store `"_113088d1..."` |

**SWS/ReaPack/script numeric IDs change between REAPER sessions.**

```zig
// Get stable string ID for non-native actions
const name = api.reverseNamedCommandLookup(numeric_id);
// NOTE: Returns without leading underscore - prepend it!
const stable_id = try std.fmt.bufPrint(&buf, "_{s}", .{name});
```

---

## 13. Testing

### Run Tests Before Committing

```bash
make test          # All tests
cd extension && zig build test  # Extension only
```

### Live Testing with REAPER

**INVOKE THE `/reamo-ws` SKILL** to test WebSocket commands against a running REAPER instance:

```
/reamo-ws tracks/subscribe {"startIdx": 0, "endIdx": 10}
```

This skill sends commands directly to the extension and shows responses — useful for debugging handlers without rebuilding the frontend. Use it to verify your handler works before writing tests.

### Test Pattern

```zig
test "handleFoo validates input" {
    var mock = MockBackend{};
    var response = TestResponseWriter{};

    // Missing required param
    const cmd = CommandMessage{ .command = "feature/foo" };
    handleFoo(&mock, cmd, &response);

    try testing.expect(response.has_error);
    try testing.expectEqualStrings("MISSING_PARAM", response.error_code);
}
```

---

## Summary

### Core Safety Rules

1. **Stack safety**: Use scratch arena, never >1KB stack buffers in timer callbacks
2. **FFI correctness**: Sentinel slices for C strings, careful with @ptrCast
3. **Error handling**: Never silent failures, always log or return error
4. **Numeric safety**: Always use `ffi.safeFloatToInt()`, never raw `@intFromFloat`
5. **Input validation**: Check all params, guard division, normalize ranges

### REAPER API Rules

6. **Master track**: idx=0 in our API, use `getTrackByUnifiedIdx()`, not `GetTrack(proj, 0)`
7. **Master mute/solo**: Use `getMasterMuteFlags()`, not `GetMediaTrackInfo_Value()`
8. **Pointer validation**: Validate before use — tracks can be deleted mid-operation
9. **Undo blocks**: Prefix with `"REAmo: "`, never nest

### Architecture Rules

10. **Threading**: All REAPER API calls on main thread only
11. **Registry**: Always add handlers to registry.zig
12. **Backend pattern**: raw → real → mock, validateBackend catches errors
13. **Response size**: Use `successLargePayload()` for anything potentially >500 bytes

When in doubt, grep for existing patterns in `actions.zig`, `fx.zig`, `inputs.zig`.
