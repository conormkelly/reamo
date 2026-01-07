# Zig error handling for JSON serialization in real-time systems

Your `catch return null` pattern is **idiomatic Zig** but represents a design smell—TigerBeetle, Bun, and Mach all avoid this problem through architectural choices rather than graceful error handling. The core insight from production Zig codebases: **size your buffers to never overflow, and treat overflow as a bug to fix, not a condition to handle gracefully**.

## Zig 0.15's new I/O interface simplifies your pattern

Zig 0.15 introduced a redesigned I/O system ("Writergate") that actually makes your use case cleaner. The new `std.Io.Writer` interface has buffering built into the interface itself, and provides a `.fixed()` constructor specifically for bounded buffer scenarios.

**The idiomatic 0.15 pattern for your `toJson`:**

```zig
const std = @import("std");
const builtin = @import("builtin");

pub fn toJson(state: *const State, buffer: []u8) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    
    std.json.stringify(state, .{}, &writer) catch |err| {
        // Single catch point for all serialization errors
        if (builtin.mode == .Debug) {
            std.log.warn("JSON serialization failed: {s}", .{@errorName(err)});
        }
        return null;
    };
    
    return writer.buffered();
}
```

Key differences from pre-0.15:
- **No `fixedBufferStream` wrapper needed** — `std.Io.Writer.fixed()` directly creates a bounded writer
- **`.buffered()` replaces `.getWritten()`** — cleaner API for retrieving output
- **Buffer lives in the interface** — better optimization, less indirection

If you encounter compatibility issues with `std.json.stringify` and the new writer (some 0.15-dev builds had missing methods), use `std.json.Stringify` directly:

```zig
pub fn toJson(state: *const State, buffer: []u8) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var jw: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    
    jw.write(state) catch {
        return null;
    };
    
    return writer.buffered();
}
```

## TigerBeetle's radical approach eliminates serialization entirely

TigerBeetle avoids your problem by design: they use **zero serialization**. Inspired by Cap'n Proto, they define fixed-size structs (128 bytes for both Account and Transfer types) that are directly memory-mapped over the wire. From their architecture docs: "Clients write the bytes of the account or transfer struct over the wire. TigerBeetle casts the bytes back... Zero-copy."

Their buffer philosophy is instructive. TigerBeetle pre-calculates **exactly** how many messages can exist at any time using comptime constants that sum every possible use—journal I/O depth, client table size, pipeline depth, connection queues. Getting a message from their pool cannot fail because they've mathematically proven capacity exists. When they do hit limits (too many client connections), they **drop connections entirely** rather than silently failing operations.

The pattern that maps to your situation: TigerBeetle uses `AssumeCapacity` methods that panic if capacity is exceeded. Their philosophy is that if your buffer overflows, you have a bug in your capacity calculation, not a runtime condition to handle. From their style guide: "Handle all errors. Ignoring errors can lead to undefined behavior, security issues, or crashes."

## Your `catch return null` pattern is acceptable but improvable

The Zig community considers `catch return null` idiomatic when the function returns an optional and errors genuinely cannot be recovered. Key points from documentation and GitHub discussions:

- **Use `catch return null`, not `catch |_| return null`**—the error capture with discard produces a compiler error in recent Zig versions
- **`catch {}` and `catch return <value>`** are explicitly documented patterns for intentionally discarding errors
- Andrew Kelley designed Zig partly for real-time audio (his Genesis DAW project), acknowledging that missing timing deadlines is as bad as crashing

However, having 150 instances of identical silent failure handling suggests a design issue worth addressing. The Zig ethos favors making intent explicit—a comment like `// Best-effort serialization: buffer overflow acceptable for metrics` transforms silent failure into documented behavior.

## Bun and Mach show hot-path buffer management patterns

Bun uses a `MutableString` wrapper around `ArrayListUnmanaged(u8)` with explicit error types—only `OutOfMemory` can fail, making errors predictable. Their hot-path patterns:

```zig
// Pre-check capacity before serialization begins
try buffer_writer.buffer.list.ensureTotalCapacity(ctx.allocator, estimated_size);

// Then serialize—only structural errors possible, not capacity
var writer = JSPrinter.BufferPrinter.init(buffer_writer);
try std.json.stringify(state, .{}, writer.writer());
```

Bun also uses **object pooling** with fixed maximum counts at comptime, avoiding per-allocation overhead. Their error handling is stratified: `catch unreachable` for mathematically impossible conditions (known-sufficient buffer), `catch {}` for non-critical operations (logging failures), and explicit error propagation for recoverable conditions.

Mach engine follows a strict **init → tick → shutdown** pattern where all allocations happen in init, and the tick loop (your equivalent of 30Hz polling) performs zero allocations. Their audio subsystem uses fixed buffer constants like `DefaultBufferSize = 512`.

## std library features for 0.15

**`std.Io.Writer.fixed()`** is your primary tool for bounded JSON output in 0.15+:

```zig
pub fn serializeState(state: *const AppState, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.stringify(state, .{}, &writer);
    return writer.buffered();
}
```

The error is propagated cleanly. For tracking remaining capacity mid-serialization or implementing graceful degradation, you can check `writer.buffer.len - writer.end` to see remaining space.

For custom serialization with capacity awareness:

```zig
const BudgetedSerializer = struct {
    writer: *std.Io.Writer,
    
    pub fn remainingCapacity(self: *const @This()) usize {
        return self.writer.buffer.len - self.writer.end;
    }
    
    pub fn writeIfFits(self: *@This(), data: []const u8) bool {
        if (self.remainingCapacity() < data.len) return false;
        self.writer.writeAll(data) catch return false;
        return true;
    }
};
```

**No comptime JSON size calculation exists** because string escaping makes sizes runtime-dependent. For conservative estimation, use a two-pass approach with a counting writer, or apply a 2-4x safety multiplier based on your data characteristics.

## Evaluating your five options

**Option A (logging at each catch)**: Unnecessary verbosity. Instead, add a single metric counter: `metrics.serialization_overflows += 1` at your centralized catch point, then monitor that counter. 150 log statements are noise; one incrementing counter is signal.

**Option B (writeJson with single catch point)**: **This is the right direction**. Centralizing error handling into a `writeJson` wrapper provides one place to log, count, and handle overflow. The 0.15 pattern:

```zig
const std = @import("std");
const builtin = @import("builtin");

// Metrics for monitoring (could be atomic for thread safety)
var metrics: struct {
    dropped_events: usize = 0,
} = .{};

pub fn toJson(state: *const State, buffer: []u8) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    
    std.json.stringify(state, .{}, &writer) catch |err| {
        metrics.dropped_events += 1;
        if (builtin.mode == .Debug) {
            std.log.warn("JSON overflow: buffer={d}, error={s}", .{
                buffer.len, @errorName(err)
            });
        }
        return null;
    };
    
    return writer.buffered();
}
```

**Option C (return error instead of null)**: Correct that the caller cannot meaningfully handle it. However, consider returning a richer type: `struct { data: ?[]const u8, overflow: bool }` lets callers know when data was dropped without forcing them to handle it.

**Option D (dynamic resizing)**: Avoid allocation in your 30Hz hot path. Both Bun and Mach pre-allocate or pool buffers. If you must grow, use `clearRetainingCapacity()` between frames—the allocation happens once, then reuses capacity.

**Option E (pre-calculate size)**: Impractical for JSON. String content, escape sequences, and nested structure make comptime calculation impossible. The two-pass counting approach works but doubles serialization cost.

## The strongest recommendation: size buffers correctly

The TigerBeetle approach is most applicable: **treat buffer overflow as a bug in your sizing, not a runtime condition**. Here's how to implement this:

1. **Profile your actual worst-case state**: Run REAPER through typical usage and log `writer.buffered().len` after each successful serialization. Find the 99.9th percentile size.

2. **Set buffer to worst-case × 1.5**: If your worst-case observed is 8KB, use 12KB. This accounts for edge cases you haven't hit yet.

3. **Add an overflow assertion in debug builds**:

```zig
const std = @import("std");
const builtin = @import("builtin");

pub fn toJson(state: *const State, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    
    std.json.stringify(state, .{}, &writer) catch |err| {
        // In debug: crash loudly so you can fix the buffer size
        if (builtin.mode == .Debug) {
            std.debug.panic("JSON buffer overflow - increase buffer size: {s}", .{@errorName(err)});
        }
        // In release: degrade gracefully but track it
        metrics.overflow_count += 1;
        return buffer[0..0]; // Empty slice indicates failure
    };
    
    return writer.buffered();
}
```

This gives you TigerBeetle's "crash on bugs, never silently fail" behavior in development, with graceful degradation in production while alerting you to fix the underlying sizing issue.

## Graceful degradation does exist, but probably isn't what you need

Game networking has established **priority-based replication** patterns: Unreal Engine assigns `NetPriority` values to actors, serializing high-priority data first and dropping low-priority data under bandwidth pressure. You could implement tiered serialization:

```zig
const std = @import("std");

const SerializePriority = enum { essential, important, optional };

fn serializeWithBudget(state: *State, buffer: []u8) struct { data: []const u8, priority_reached: SerializePriority } {
    var writer: std.Io.Writer = .fixed(buffer);
    
    // Essential: must fit or fail entirely
    std.json.stringify(state.essential, .{}, &writer) catch {
        return .{ .data = buffer[0..0], .priority_reached = .essential };
    };
    
    // Important: serialize if space remains
    const remaining = writer.buffer.len - writer.end;
    if (remaining > 256) {
        std.json.stringify(state.important, .{}, &writer) catch {};
    }
    
    // Optional: best-effort
    std.json.stringify(state.optional, .{}, &writer) catch {};
    
    return .{ .data = writer.buffered(), .priority_reached = .optional };
}
```

However, **this adds significant complexity**. For your use case (state broadcast to WebSocket clients at 30Hz), simpler is better: size your buffer correctly, and if overflow ever occurs, log it and fix the sizing. Your WebSocket clients can handle occasional dropped frames—they're already dealing with network latency and packet loss.

## Concrete action plan

1. **Centralize to `toJson`** (Option B) with a single catch point that increments a metric counter, using the 0.15 `std.Io.Writer.fixed()` pattern
2. **Profile actual buffer usage** over a week of real usage to find true worst-case size
3. **Size buffer to 1.5× worst-case**, then treat overflow as a bug
4. **Add debug-only panic** on overflow to catch sizing regressions during development
5. **Consider delta serialization** if buffer size becomes impractical—send full state initially, then only changed fields, dramatically reducing per-frame payload

The pattern from all three production Zig codebases is consistent: don't handle buffer overflow gracefully—prevent it through correct sizing, pool buffers to avoid allocation in hot paths, and treat overflow as a bug to fix rather than a runtime condition to manage.

---

## References

- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html) — I/O interface redesign details
- [Zig std.json.Stringify source](https://github.com/ziglang/zig/blob/master/lib/std/json/dynamic_test.zig) — Official usage patterns with `std.Io.Writer.fixed()`
- [Bun pool.zig](https://github.com/oven-sh/bun/blob/main/src/pool.zig) — Object pooling patterns
- [Mach engine documentation](https://machengine.org/) — Init/tick/shutdown allocation patterns