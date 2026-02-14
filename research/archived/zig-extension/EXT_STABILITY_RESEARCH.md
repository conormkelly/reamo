# Zig REAPER Extension Stability Guide for Reamo

A native plugin running inside REAPER's process faces unique constraints: it **cannot crash**, must handle thread communication safely, and needs proper shutdown for extension reload scenarios. This report addresses all 10 stability issues with specific, actionable recommendations for the Reamo WebSocket control surface project.

## Issue 1: WebSocket thread shutdown requires EVFILT_USER wake-up

The current "detach and ignore" workaround is **unsafe for REAPER extension reloads**. When REAPER calls `ReaperPluginEntry(hInstance, NULL)`, signaling unload, the extension must properly release resources. Detached threads holding bound ports will cause bind failures on reload, and zombie threads may reference unloaded code.

The core problem is that websocket.zig's `stop()` blocks indefinitely because worker threads are stuck in `kevent()` (macOS) or `epoll_wait()` (Linux) with no timeout. The proper solution is **EVFILT_USER** on macOS or **eventfd** on Linux—these provide clean mechanisms to wake blocked I/O threads.

For kqueue, register a user event at startup with `EV_ADD | EV_CLEAR`, then trigger shutdown by calling `kevent()` with `NOTE_TRIGGER` in the fflags. This pattern is used by libevent and was recently adopted by Go's runtime. For epoll, create an eventfd, add it to the epoll set, then write to it from the shutdown thread. The recommended shutdown sequence is: set atomic shutdown flag, trigger wake-up event, join threads with timeout, close listening socket, release resources.

**Recommendation**: Fork websocket.zig to add EVFILT_USER/eventfd support, or switch to mitchellh/libxev which has explicit shutdown support. Never rely solely on process exit cleanup.

## Issue 2: Float validation needed at REAPER API boundaries

Zig's `@intFromFloat` is classified as "detectable illegal behavior"—it **will panic** on NaN, Infinity, or any value outside the destination integer's representable range. The safeFloatToInt helper approach is correct.

REAPER's API documentation does not explicitly address NaN/Inf return values from functions like `GetMediaTrackInfo_Value()` or `TimeMap2_timeToBeats()`. However, corrupt values can occur when accessing deleted objects through stale pointers. The `TimeMap2_timeToBeats()` function has known issues with many tempo markers (Cockos forum #142449), suggesting edge cases exist.

**Best practice**: Check at trust boundaries rather than everywhere. Validate all floats received from REAPER APIs before `@intFromFloat` conversion:

```zig
fn safeFloatToInt(comptime T: type, value: f64) ?T {
    if (!std.math.isFinite(value)) return null;
    const min_val = @as(f64, @floatFromInt(std.math.minInt(T)));
    const max_val = @as(f64, @floatFromInt(std.math.maxInt(T)));
    if (value < min_val or value > max_val) return null;
    return @intFromFloat(value);
}
```

Use `ValidatePtr2()` to verify track/item pointers before API calls, as invalid pointers are the likely source of corrupt return values.

## Issue 3: Input validation before TimeMap2_timeToBeats calls

The function accepts a time parameter in seconds and returns beats. No documentation specifies behavior with NaN/Inf inputs, but passing invalid floats to REAPER APIs is undefined behavior. Additionally, `TimeMap2_timeToBeats` has documented bugs with complex tempo maps.

**Recommendation**: Validate the time parameter before calling—check `std.math.isFinite(time)` and ensure non-negative values. Validate the returned beats value before any `@intFromFloat` conversion. For beat formatting, consider clamping outputs to reasonable ranges (e.g., **0 to 1,000,000 beats**) as a defense-in-depth measure.

## Issue 4: Use std.json for automatic escaping

REAPER ExtState values stored via `GetExtState()`/`SetExtState()` have these constraints: single-line only (newlines truncated on persistence), trailing spaces may be removed, and non-ASCII characters may not survive the INI file storage format. Quotes and backslashes work within a session but require careful handling.

Building JSON manually with string concatenation is dangerous. Instead, use `std.json.writeStream` which automatically escapes control characters (0x00-0x1F), backslashes, double quotes, and optionally Unicode:

```zig
var out = std.ArrayList(u8).init(allocator);
var stream = std.json.writeStream(out.writer(), .{});
try stream.beginObject();
try stream.objectField("extstate_value");
try stream.write(potentially_dangerous_string); // Auto-escaped
try stream.endObject();
```

For ExtState specifically, consider BASE64 encoding complex data to avoid any character issues with REAPER's INI file persistence.

## Issue 5: Atomic operations required for setTimePreciseFn

The comment claiming "no mutex needed because set before any requests" is **incorrect**—there's a real race condition. The WebSocket server starts immediately, and a client could send `clockSync` before `setTimePreciseFn` completes on the main thread. Without synchronization, the reader thread might see a partially-written pointer or stale memory.

Zig provides `std.atomic.Value` for exactly this pattern:

```zig
const FnPtr = *const fn () f64;
var timePreciseFn: std.atomic.Value(?FnPtr) = std.atomic.Value(?FnPtr).init(null);

// Main thread sets (once)
pub fn setTimePreciseFn(ptr: FnPtr) void {
    timePreciseFn.store(ptr, .release);
}

// WebSocket thread reads
pub fn getTimePreciseFn() ?FnPtr {
    return timePreciseFn.load(.acquire);
}
```

The `.release` ordering on store ensures all prior memory writes are visible; `.acquire` on load synchronizes with that store. Alternatively, use `std.once` for one-time initialization that's guaranteed thread-safe.

## Issue 6: Never silently swallow allocation failures

Using `catch {}` for allocation failures is dangerous—it leaves data structures in inconsistent states, causes resource leaks, and makes debugging nearly impossible. For a "must not crash" context, handle allocation failures explicitly.

**Recommended patterns**:

- **Return errors**: Use `!Result` return types and `try` to propagate allocation failures up the call stack where they can be handled appropriately
- **Pre-allocate for cleanup**: Reserve emergency buffers at startup using `FixedBufferAllocator` for operations that must succeed during shutdown
- **Arena allocators**: For batch operations, use `ArenaAllocator` which frees all allocations together, eliminating individual cleanup failures
- **Graceful degradation**: When allocation fails for non-critical operations, log the failure and continue with reduced functionality

```zig
const CleanupContext = struct {
    emergency_buffer: [4096]u8 = undefined,
    
    fn safeCleanup(self: *@This()) void {
        var fba = std.heap.FixedBufferAllocator.init(&self.emergency_buffer);
        // Cleanup using pre-allocated memory—cannot fail
    }
};
```

## Issue 7: Move large allocations to heap

REAPER does not document stack size limits for extension callbacks, but **512KB on stack is extremely risky**. Default thread stack sizes are typically 1MB on Linux and 512KB on macOS secondary threads. Timer callbacks likely run on REAPER's main thread with unknown stack constraints.

**Recommendation**: Move large buffers to heap allocation:

- Audio peaks (512KB): Allocate once at startup, reuse
- Notes buffer (64KB): Use arena allocator per request
- JSON buffer (32KB): Use `ArrayList` with pre-reserved capacity

For temporary large buffers needed during a single operation, use `ArenaAllocator`:

```zig
fn processLargeData(parent_allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();  // Frees everything at once
    const temp = try arena.allocator().alloc(u8, 512 * 1024);
    // ... use temp
}
```

## Issue 8: Report limit exceeded errors to clients

Professional projects can be massive: orchestral templates reach **1,000-2,000 tracks**, complex sessions have **10,000-50,000 items**, and large arrangements use **hundreds of markers**. The current limits (MAX_ITEMS=512, MAX_TRACKS=128) are too low for professional use.

Silent truncation is problematic—it hides the issue and causes mysterious behavior. SQL Server 2019 explicitly added detailed truncation messages because silent truncation was a major developer pain point.

**Recommended approach**:

- Increase limits to reasonable maximums: **2,000 tracks**, **10,000 items**, **1,000 markers**
- Log warnings when approaching limits (e.g., at 80% capacity)
- Return explicit errors to WebSocket clients when limits are exceeded, including current count and maximum
- Include limit information in API documentation

```zig
if (items.len >= MAX_ITEMS) {
    log.warn("Item limit reached: {} of {}", .{items.len, MAX_ITEMS});
    return error.LimitExceeded;  // Client receives clear error message
}
```

## Issue 9: I_CURTAKE can return -1 for empty items

The `I_CURTAKE` property returns the active take number as an integer. While documentation doesn't explicitly state this, items with **no takes** or in certain edge states may return **-1** to indicate no active take. Casting a negative `c_int` to `usize` would produce a massive value, causing out-of-bounds access.

**Safe pattern**:

```zig
const cur_take_raw = @as(c_int, @intFromFloat(api.getMediaItemInfo_Value(item, "I_CURTAKE")));
const take_count = api.getMediaItemNumTakes(item);

if (cur_take_raw >= 0 and cur_take_raw < take_count) {
    const cur_take_idx: usize = @intCast(cur_take_raw);
    const take = api.getMediaItemTake(item, cur_take_idx);
    // ... process take
}
```

Always bounds-check against `GetMediaItemNumTakes()` before using the index.

## Issue 10: Implement runtime-configurable file logging

Requiring recompilation for debug logging is impractical. Host applications often lack an attached console, making file logging essential.

**Recommended implementation**:

- **Runtime log levels via environment variable**: `REAMO_LOG_LEVEL=DEBUG`
- **File logging with rotation**: Write to user's REAPER resource path (e.g., `~/.config/REAPER/reamo.log`)
- **Log levels**: DEBUG (internal state), INFO (key events), WARN (limits approached, retries), ERROR (failures, panics)
- **Always log**: Initialization failures, thread panics, resource exhaustion, unhandled conditions—anything crash-relevant should be ERROR level and always logged regardless of configured level

```zig
const log_level = std.posix.getenv("REAMO_LOG_LEVEL") orelse "WARN";
const log_path = getReaperResourcePath() ++ "/reamo.log";
```

Include timestamp, thread ID, and component name in each log entry for effective debugging.

## Thread safety requirements for REAPER APIs

Most REAPER API calls are **main thread only**. The documentation explicitly marks `CreateTakeAudioAccessor`, `CreateTrackAudioAccessor`, `DestroyAudioAccessor`, and `AudioAccessorValidateState` as main-thread-only, and the general rule from experienced developers is that "almost nothing of REAPER should leave the main thread."

Reamo's architecture is correct: WebSocket operations should never directly call REAPER APIs. Use the SharedState mutex pattern to queue commands from the WebSocket thread, then process them in the timer callback on the main thread. Never block the main thread waiting for WebSocket responses.

## Conclusion

The highest-priority fixes are the **WebSocket shutdown race condition** (Issue 1) and **thread-safe function pointer access** (Issue 5)—both are real race conditions that could cause crashes or undefined behavior. The float validation issues (2, 3) and allocation failure handling (6) represent defense-in-depth that prevents crashes from unexpected REAPER behavior.

For the WebSocket shutdown, forking websocket.zig to add EVFILT_USER/eventfd support is the cleanest solution; this is well-documented in libevent's implementation. For thread safety, consistently use `std.atomic.Value` with acquire/release ordering for any cross-thread data access.

The fixed limits (Issue 8) should be increased significantly and errors reported to clients—professional REAPER projects regularly exceed the current limits. Stack usage (Issue 7) should be moved to heap with arena allocators for predictable memory behavior. Runtime logging (Issue 10) will make debugging production issues tractable without requiring recompilation and reinstallation.
