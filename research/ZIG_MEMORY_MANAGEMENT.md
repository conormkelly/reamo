# Zig buffer allocation patterns for REAPER timer callbacks

**For your 128KB JSON formatting buffer in REAPER timer callbacks, the idiomatic Zig solution is heap-allocated scratch memory with `FixedBufferAllocator` for fast reset—your current static storage approach is also valid for single-threaded contexts but comes with reentrancy caveats.** All standard allocators including `c_allocator` are safe in REAPER timer callbacks since they execute on the main thread, not the real-time audio thread.

## Timer callbacks are main-thread—allocation is safe

REAPER's `plugin_register("timer", func_ptr)` callbacks run on the **main/UI thread** at approximately 30Hz, fundamentally different from audio callbacks registered via `Audio_RegHardwareHook()`. This distinction is critical:

| Callback Type | Thread | malloc/free Safe? | Blocking Safe? |
|---------------|--------|-------------------|----------------|
| Timer (`plugin_register`) | Main/UI | ✅ Yes | ✅ Yes |
| Audio Hook (`OnAudioBuffer`) | Audio RT | ❌ No | ❌ No |

Since timer callbacks execute during REAPER's main message loop idle time, **`std.heap.c_allocator` is completely safe**. It wraps libc's `malloc`/`free`, which are thread-safe operations on all modern platforms. The real-time audio programming constraints from Ross Bencina's guidelines—no allocation, no locks, no syscalls—apply only to audio thread callbacks, not timer callbacks.

Your concern about deeply nested modal dialogs (~45+ stack frames) is valid but affects callback **scheduling reliability**, not allocation safety. During modal dialogs, timer callbacks may fire less reliably as the main message loop is blocked, but any allocation performed when they do fire remains safe.

## The idiomatic pattern: heap-backed FixedBufferAllocator

The Zig community strongly recommends **never stack-allocating large buffers** (128KB absolutely qualifies). The idiomatic pattern for callback-driven code combines heap allocation at initialization with `FixedBufferAllocator` for O(1) reset between uses:

```zig
const std = @import("std");

pub const CallbackContext = struct {
    scratch_buffer: []u8,
    scratch_fba: std.heap.FixedBufferAllocator,
    parent_allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !CallbackContext {
        const scratch = try allocator.alloc(u8, 128 * 1024);
        return .{
            .scratch_buffer = scratch,
            .scratch_fba = std.heap.FixedBufferAllocator.init(scratch),
            .parent_allocator = allocator,
        };
    }
    
    pub fn deinit(self: *CallbackContext) void {
        self.parent_allocator.free(self.scratch_buffer);
    }
    
    /// Call at start of each timer callback
    pub fn resetScratch(self: *CallbackContext) void {
        self.scratch_fba.reset(); // O(1) - just resets index to 0
    }
    
    pub fn scratchAllocator(self: *CallbackContext) std.mem.Allocator {
        return self.scratch_fba.allocator();
    }
};
```

This pattern allocates once during plugin initialization, then provides **zero-syscall scratch allocation** during callbacks. The `reset()` operation is trivially cheap—it simply sets an internal index back to zero. For your JSON formatting use case, you'd reset at the start of each timer callback, format into the scratch buffer, send the response, then let the next callback reset again.

## Static storage is valid but carries reentrancy warnings

Your current approach using function-local static storage (`const S = struct { var buf: [128*1024]u8 = undefined; };`) is **acceptable for single-threaded main-thread execution** but the Zig community has documented concerns:

The pattern creates what Zig documentation calls a "Static Local Variable"—the buffer persists across function calls but is **not reentrant**. If your timer callback could ever be called recursively (unlikely in REAPER) or if you might have multiple extensions sharing the same code, static storage would cause data corruption. The Zig closure implementation documentation explicitly warns: "After invoking the bind function you are required to finish using the closure generated before invoking it again. Otherwise the static local variable will be overwritten."

**Community consensus from GitHub issue #4107:** Prefer passing state through function parameters over mutable statics, but static storage is valid when single-threaded use is guaranteed and well-documented. For plugin code, the key pitfall is that **multiple plugin instances would share the same static buffer**—unlikely to matter for a REAPER extension but problematic for VST/CLAP plugins.

Trade-offs between static and heap:

| Static Storage | Heap Allocation |
|----------------|-----------------|
| Zero allocation overhead | Single allocation at init |
| Fixed at compile time | Dynamic sizing possible |
| No allocator parameter needed | Requires allocator |
| NOT reentrant | Fully reentrant |
| Memory always consumed | Freed when done |

## ArenaAllocator and scratch patterns in practice

Beyond `FixedBufferAllocator`, Zig offers several patterns for transient allocation:

**ArenaAllocator** wraps any backing allocator and provides batch-free semantics—all allocations freed simultaneously on `deinit()` or `reset()`. Useful when you need multiple temporary allocations of varying sizes:

```zig
fn formatJsonResponse(backing: std.mem.Allocator, data: anytype) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit(); // Frees ALL allocations at once
    
    const aa = arena.allocator();
    // Multiple temporary allocations during formatting...
    const result = try std.json.stringifyAlloc(aa, data, .{});
    return result;
}
```

For your specific 128KB JSON formatting scenario, **`std.fmt.bufPrint` is often cleaner than using an allocator** when the size is bounded:

```zig
fn formatResponse(buf: []u8, data: anytype) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}", .{std.json.stringify(data)});
}
```

The TigerBeetle pattern (discussed extensively on Ziggit) takes this further: **allocate ALL memory at startup** with compile-time-derived bounds, accept zero runtime allocation. This is overkill for timer callbacks but represents the extreme end of the determinism spectrum.

## Recommended implementation for your use case

Given your constraints—single-threaded main thread, transient buffer use, stack overflow risk—here's the recommended approach:

```zig
const std = @import("std");

// Global context initialized once during ReaperPluginEntry
var g_context: ?*PluginContext = null;

const PluginContext = struct {
    json_buffer: []u8,
    allocator: std.mem.Allocator,
    
    pub fn init() !*PluginContext {
        const allocator = std.heap.c_allocator; // Safe for main thread
        const ctx = try allocator.create(PluginContext);
        ctx.* = .{
            .json_buffer = try allocator.alloc(u8, 128 * 1024),
            .allocator = allocator,
        };
        return ctx;
    }
    
    pub fn deinit(self: *PluginContext) void {
        self.allocator.free(self.json_buffer);
        self.allocator.destroy(self);
    }
};

// Timer callback - called from REAPER main thread
export fn onTimerCallback() callconv(.C) void {
    const ctx = g_context orelse return;
    
    // Format JSON into pre-allocated buffer
    const json = std.fmt.bufPrint(ctx.json_buffer, "{{\"data\": ...}}", .{...}) 
        catch return;
    
    // Send response
    sendResponse(json);
    // Buffer automatically available for next callback
}
```

This provides **heap safety** (no stack overflow), **deterministic performance** (no allocation during callbacks), and **clear ownership** (context owns the buffer). If you prefer the simplicity of static storage and accept the reentrancy limitation, your current approach remains valid—just document that the buffer is non-reentrant.

## Allocator selection guidance

For release builds of REAPER extensions, the Zig 0.14+ recommended pattern:

```zig
const gpa, const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => .{ std.heap.DebugAllocator(.{}).allocator(), true },
    .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
};
```

`c_allocator` remains valid when linking libc (which REAPER extensions require anyway via the C ABI), but `smp_allocator` is the current recommendation for production multithreaded code. For your single-threaded timer callback context, either works equivalently.

## Conclusion

Your static storage approach works for single-threaded REAPER timer callbacks. The more idiomatic Zig pattern—heap-allocated buffer with `FixedBufferAllocator` or direct `bufPrint`—provides the same performance with better reentrancy safety and explicit ownership semantics. Since timer callbacks run on the main thread, all standard allocators including `c_allocator` are safe to use. Reserve allocation-free patterns for audio thread callbacks only.
