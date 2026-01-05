# Zig 0.15 best practices for a safety-critical REAPER plugin

Your WebSocket-based control surface presents a challenging intersection of Zig idioms, C FFI safety, real-time constraints, and "never crash" requirements. The good news: **your core patterns are sound**, with refinements that can improve safety and performance. This report addresses each of your seven specific questions with concrete recommendations based on Zig 0.15 semantics and plugin development best practices.

## Your atomic function pointer pattern is correct but suboptimal

The release/acquire ordering for your `time_precise_fn_ptr` is **semantically correct**. Release on store ensures all preceding writes are visible before the pointer becomes available; acquire on load ensures subsequent reads see those writes. This is the textbook pattern for publishing a function pointer with associated data.

However, storing function pointers as `usize` via `@intFromPtr/@ptrFromInt` adds unnecessary type gymnastics. **Zig's `std.atomic.Value` supports pointer types directly**, including optional pointers:

```zig
// More idiomatic in Zig 0.15:
time_precise_fn: std.atomic.Value(?TimePreciseFn) = std.atomic.Value(?TimePreciseFn).init(null),

pub fn setTimePreciseFn(self: *SharedState, func: TimePreciseFn) void {
    self.time_precise_fn.store(func, .release);
}

pub fn timePreciseMs(self: *SharedState) f64 {
    if (self.time_precise_fn.load(.acquire)) |func| {
        return func() * 1000.0;
    }
    return 0;
}
```

This eliminates the integer conversion and makes the code's intent clearer. The `?TimePreciseFn` type explicitly communicates that the pointer may be null, and the `if` unwrap is idiomatic Zig.

## Single mutex is risky at 30Hz polling frequency

A single mutex protecting your command queue, client map, and miscellaneous state creates **serialization bottlenecks** even when accessing independent data. At 30Hz timer callbacks, this may not cause visible problems today, but it introduces latency spikes when the WebSocket thread holds the lock during client iteration while the timer callback waits.

**The real risk is priority inversion**: if your WebSocket thread (lower priority) holds the mutex when REAPER's timer fires, the timer callback blocks until the WebSocket operation completes. This violates real-time audio principles even though your timer isn't on the audio thread.

Recommended refactoring uses **fine-grained locks**:

```zig
const SharedState = struct {
    // Separate locks for independent resources
    command_lock: std.Thread.Mutex = .{},
    commands: std.ArrayList(Command),
    
    client_lock: std.Thread.RwLock = .{},  // RwLock for read-heavy client iteration
    clients: std.AutoHashMap(u32, Client),
    
    // Atomics for simple values (no lock needed)
    transport_state: std.atomic.Value(TransportState) = .init(.stopped),
};
```

For the command queue specifically, consider a **lock-free SPSC queue** since you have exactly one producer (WebSocket thread) and one consumer (timer callback). The standard library's `std.atomic.Queue` provides lock-free MPSC semantics, or implement a simple ring buffer for SPSC.

## Static storage for 4MB state is appropriate but imperfect

Your `ProcessingState` pattern with static storage **avoids stack overflow** (correct concern—typical stacks are 1-8MB, and deeply nested callbacks compound the risk) and **eliminates allocation failures** during callbacks (critical for stability).

```zig
const ProcessingState = struct {
    var snap_tracks: tracks.State = .{};  // ~2.5MB
    var cur_tracks: tracks.State = .{};   // ~2.5MB
};
```

The **risks of this pattern**:
- No automatic thread safety (you must synchronize access)
- Testing difficulty (global state complicates unit tests)
- Binary size inflation (4MB embedded in your extension)

For a plugin with a single instance per process, this is acceptable. The alternative—heap allocation at plugin init—provides more flexibility but introduces allocation failure handling:

```zig
var g_state: ?*ProcessingState = null;

export fn plugin_init() c_int {
    g_state = std.heap.c_allocator.create(ProcessingState) catch return 0;
    return 1;
}
```

## The 2.5MB state copy is a real performance concern

At 30Hz with change detection triggering `g_last_tracks = cur_tracks`, you're potentially copying **2.5MB every ~33ms**. Modern memory bandwidth handles this (~1-3ms per copy), but it consumes **6-18% of your frame budget** unnecessarily.

**Double buffering with atomic pointer swap** eliminates the copy entirely:

```zig
const StateBuffer = struct {
    buffers: [2]tracks.State = .{.{}, .{}},
    active: std.atomic.Value(u1) = .init(0),
    
    // Timer callback reads from active buffer (lock-free)
    pub fn current(self: *const StateBuffer) *const tracks.State {
        return &self.buffers[self.active.load(.acquire)];
    }
    
    // Updater modifies inactive buffer, then swaps
    pub fn staging(self: *StateBuffer) *tracks.State {
        return &self.buffers[1 - self.active.load(.monotonic)];
    }
    
    pub fn commit(self: *StateBuffer) void {
        const current_active = self.active.load(.monotonic);
        self.active.store(1 - current_active, .release);
    }
};
```

**Workflow**: populate `staging()`, call `commit()`, readers immediately see new state via `current()`. The old buffer becomes the new staging area. No copy required—just a pointer swap.

**Trade-off**: 2× memory usage (5MB instead of 2.5MB for tracks). For your use case, this is worthwhile given the CPU savings.

## Your safeFloatToInt is almost complete

The pattern correctly handles the critical cases:

```zig
pub fn safeFloatToInt(comptime T: type, value: f64) FFIError!T {
    if (std.math.isNan(value)) return error.FloatIsNaN;
    if (std.math.isInf(value)) return error.FloatIsInf;
    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));
    if (value < min_val or value > max_val) return error.IntegerOverflow;
    return @intFromFloat(value);
}
```

**Edge cases covered**: NaN, ±Infinity, out-of-range values. **Safe cases that don't need handling**: denormalized floats (valid small numbers), negative zero (converts to 0), values at exact boundaries (255.0 → u8 works fine).

**One subtle issue**: for unsigned target types, negative floats should also be rejected. Your range check handles this implicitly since `min_val` for unsigned types is 0, but adding explicit documentation or a separate check makes the intent clearer:

```zig
// For unsigned types, explicitly reject negative values
if (@typeInfo(T).int.signedness == .unsigned and value < 0) {
    return error.NegativeToUnsigned;
}
```

**Zig 0.15 behavior**: `@intFromFloat` is "detectable illegal behavior"—it panics in Debug/ReleaseSafe modes and causes undefined behavior in ReleaseFast/ReleaseSmall. Your wrapper prevents this correctly.

## ValidatePtr2 is worth the overhead for your use case

The **theoretical race window** you identified is real: between `GetTrack(proj, idx)` and using the pointer, the user could delete the track. REAPER's `ValidatePtr2` **reduces but doesn't eliminate** this TOCTOU (time-of-check-time-of-use) risk—the object could still be deleted between validation and use.

**Pragmatic recommendation**: Use ValidatePtr2 for **any pointer that crosses a yield point** or is derived from user-controlled indices:

```zig
fn processTrack(project: *c.ReaProject, track_idx: c_int) !void {
    const track = c.GetTrack(project, track_idx) orelse return error.TrackNotFound;
    
    // Validate before use—catches deleted tracks
    if (!c.ValidatePtr2(project, track, "MediaTrack*")) {
        return error.InvalidTrackPointer;
    }
    
    // Use immediately, don't store
    const name = c.GetTrackName(track);
    // ... process ...
}
```

**Skip validation** when you're iterating tracks in a tight loop within a single callback—the iteration itself validates existence, and the overhead isn't justified.

**Safest pattern**: Store GUIDs instead of pointers, re-lookup by GUID when needed:

```zig
const SafeTrackRef = struct {
    guid: [16]u8,
    project: *c.ReaProject,
    
    fn resolve(self: SafeTrackRef) ?*c.MediaTrack {
        return c.GetTrackByGUID(self.project, &self.guid);
    }
};
```

## anytype with comptime validation is idiomatic but evolving

Your pattern of `anytype` parameters with `comptime validateBackend(T)` is **used throughout Zig's standard library**, particularly for readers/writers and allocators. It's idiomatic for dependency injection and testing.

**Community nuance**: Recent standard library changes have **removed** explicit validation functions from HashMap/ArrayHashMap, instead relying on compile errors from usage. The philosophy is shifting toward "let the compiler error naturally" rather than custom validation.

**Your pattern remains valid** when you want **custom error messages** explaining what the backend must provide:

```zig
fn validateBackend(comptime T: type) void {
    if (!@hasDecl(T, "execute")) {
        @compileError("Backend must have 'execute' method");
    }
    // Additional checks...
}
```

**Testing benefit**: This enables clean mock injection without runtime overhead:

```zig
// Production
const Controller = ControlSurface(RealReaperBackend);

// Test
const TestController = ControlSurface(MockBackend);
```

## inline for dispatch is idiomatic; StaticStringMap is often better

Your command dispatch pattern:

```zig
inline for (comptime_registry.all) |entry| {
    if (std.mem.eql(u8, cmd.command, entry[0])) {
        entry[1](api, cmd, &response);
        return;
    }
}
```

This is **idiomatic and correct**. The loop unrolls at compile time, each iteration becomes a branch, and comptime-known strings enable optimizations.

**For larger command sets**, `std.StaticStringMap` provides **O(1) lookup** via length-bucketing:

```zig
const handlers = std.StaticStringMap(*const fn(*Api, *Command, *Response) void).initComptime(.{
    .{ "play", handlePlay },
    .{ "stop", handleStop },
    .{ "record", handleRecord },
    // ... many more commands
});

pub fn dispatch(api: *Api, cmd: *Command, response: *Response) void {
    if (handlers.get(cmd.command)) |handler| {
        handler(api, cmd, response);
    } else {
        response.setError("Unknown command");
    }
}
```

**Rule of thumb**: `inline for` for <10 commands, `StaticStringMap` for larger sets. The crossover point depends on string length distribution; benchmark if performance-critical.

## Semantic error hierarchy is acceptable but not strictly idiomatic

Zig uses **flat error sets**, not hierarchies. Your approach:

```zig
const FFIError = error{ NullPointer, InvalidHandle, FloatIsNaN, FloatIsInf, IntegerOverflow };
const ReaperStateError = error{ InvalidProject, TrackNotFound, InvalidState };
const ResourceError = error{ OutOfMemory, BufferFull };
```

This is **fine for documentation and organization**. You can merge them when needed:

```zig
const AllErrors = FFIError || ReaperStateError || ResourceError;
```

**More idiomatic in Zig**: Let the compiler infer error sets for internal functions (just use `!T`), and define explicit error sets only at API boundaries where you want to document possible failures.

## Cleanup should log errors but not propagate them

For plugin shutdown, **silently ignoring errors is acceptable** with one caveat: **log them** for debugging:

```zig
pub fn deinit(self: *Self) void {
    self.closeWebSocket() catch |err| {
        std.log.warn("WebSocket close failed during cleanup: {}", .{err});
    };
    
    self.freeResources() catch |err| {
        std.log.warn("Resource cleanup failed: {}", .{err});
    };
    
    // Truly unimportant cleanup can use catch {}
    _ = self.optionalCleanup() catch {};
}
```

**Rationale**: During shutdown, you're already exiting—propagating errors complicates control flow with no benefit. But logging preserves diagnostic information for debugging mysterious issues.

## No compile-time enforcement for exclusive buffer access in Zig

Zig doesn't have Rust-style borrow checking or compile-time exclusivity enforcement. Your static JSON buffers used sequentially within the timer callback are **safe by design** (single-threaded access), but the compiler can't verify this.

**Runtime enforcement options**:

```zig
const GuardedBuffer = struct {
    buffer: [8192]u8 = undefined,
    in_use: std.atomic.Value(bool) = .init(false),
    
    pub fn acquire(self: *GuardedBuffer) ?[]u8 {
        if (self.in_use.swap(true, .acquire)) {
            // Already in use—programming error in debug, graceful fail in release
            if (builtin.mode == .Debug) @panic("Buffer already in use");
            return null;
        }
        return &self.buffer;
    }
    
    pub fn release(self: *GuardedBuffer) void {
        self.in_use.store(false, .release);
    }
};
```

**Thread-local storage** for per-thread buffers:

```zig
threadlocal var scratch_buffer: [8192]u8 = undefined;

fn processInTimerCallback() void {
    // Each thread gets its own buffer—no synchronization needed
    const buffer = &scratch_buffer;
    // ...
}
```

Since your timer callback runs on REAPER's main thread exclusively, thread-local storage guarantees isolation from the WebSocket thread.

## Allocator selection for plugin contexts

**Use `std.heap.c_allocator`** when linking with libc (which you are, for REAPER). Benefits:
- Memory operations are consistent with C library allocations
- Well-tested, battle-hardened implementation
- Debugging tools (Valgrind, AddressSanitizer) understand it

**Zig 0.15 alternative**: `std.heap.smp_allocator` is a new fast, thread-safe allocator that often outperforms libc malloc. Consider for performance-critical paths, but `c_allocator` is safer for mixed C/Zig codebases.

**For development**: Wrap with `std.heap.DebugAllocator` (renamed from `GeneralPurposeAllocator` in 0.15) to catch leaks and double-frees:

```zig
const backing = std.heap.c_allocator;
var debug_alloc = std.heap.DebugAllocator(.{}).init(backing);
const allocator = if (builtin.mode == .Debug) debug_alloc.allocator() else backing;
```

## Critical safety rules for your REAPER plugin

These principles synthesize the research into actionable guidelines:

**At C boundaries, never let panics escape**. Zig panics crash REAPER—there's no recovery mechanism. Every `export fn` callback must catch all errors:

```zig
export fn timer_callback() callconv(.C) void {
    timerImpl() catch |err| {
        std.log.err("Timer callback failed: {}", .{err});
        // Don't propagate—would panic at FFI boundary
    };
}
```

**Never allocate in callbacks**. Pre-allocate all buffers at plugin initialization. Your static storage approach is correct for this reason.

**Validate external inputs exhaustively**. Every pointer from REAPER, every value from WebSocket clients—validate before use. The cost is negligible compared to a crash.

**Use "resolve, use, discard" for REAPER pointers**. Never store `MediaTrack*` across callbacks. Store indices or GUIDs, resolve to pointers when needed, use immediately, don't cache.

**Separate WebSocket operations from timer callbacks**. Network I/O can block and allocate. Your architecture with a separate WebSocket thread communicating via queues is correct—just ensure the queue operations are truly lock-free or use fine-grained locks with `tryLock` to avoid blocking the timer.

Your overall architecture demonstrates solid understanding of the constraints. The refinements above—typed atomic pointers, fine-grained locking, double buffering for state snapshots, and consistent error handling at FFI boundaries—will strengthen an already well-designed system.
