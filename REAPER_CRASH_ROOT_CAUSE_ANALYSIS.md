# Solving Zig REAPER extension stack overflow on macOS Finder launch

Your REAPER extension crashes because Zig allocates **all ~6-7MB of stack space at function entry**, combined with REAPER's deeply nested startup state (~45+ stack frames during modal dialogs), leaving insufficient room on macOS's **8MB main thread stack** when launched via Finder. The fix requires moving large State structs off the stack entirely and implementing defensive checks during REAPER's constrained startup phase.

## The root cause: Zig's eager stack allocation meets modal dialog nesting

Zig allocates the **complete stack frame at function entry**, not lazily as execution proceeds. When your `doProcessing()` function declares `tracks.State` (~2.5MB), `items.State` (~600KB), and `markers.State` (~95KB) as locals, Zig reserves the full ~6-7MB immediately—even before executing any code. This explains why the crash occurs at the function prologue (offset 24 bytes): the `__zig_probe_stack()` mechanism detects insufficient stack before any logic runs.

The Finder vs Terminal discrepancy stems from **process environment differences**, not stack size. Both launch methods provide an 8MB main thread stack, but Terminal-launched processes inherit shell configurations that may affect memory behavior. More critically, REAPER's startup sequence during Finder launch triggers modal dialogs (CheckFaultyProject, MessageBox) that create **deeply nested call stacks**—sometimes 45+ frames—before your timer callback fires. With ~45 frames consuming approximately 1-2MB, your 6-7MB allocation exceeds the remaining ~6MB.

## Primary solution: move large structs to heap or static storage

The most effective fix eliminates stack allocation entirely by using **global/static storage** or **heap allocation**.

**Static storage pattern** (recommended for plugin state):
```zig
fn doProcessing() void {
    // Static storage - lives in data section, NOT stack
    const S = struct {
        var tracks: tracks.State = undefined;
        var items: items.State = undefined;  
        var markers: markers.State = undefined;
    };
    
    S.tracks = tracks.State.init();
    processTrackState(&S.tracks);
    // ...
}
```

**Heap allocation pattern** (when you need multiple instances):
```zig
const allocator = std.heap.c_allocator; // Links with C runtime anyway

var g_state: ?*State = null;

export fn plugin_init() callconv(.C) c_int {
    g_state = allocator.create(State) catch return -1;
    g_state.?.* = State.init();
    return 0;
}

export fn process_callback() callconv(.C) void {
    const state = g_state orelse return;
    doProcessing(state); // Pass pointer, not value
}
```

Use `std.heap.c_allocator` for REAPER plugins since you're already linking against the C runtime. Alternatively, `std.heap.page_allocator` works without libc but incurs slightly more overhead.

**Verify struct sizes at compile time** to catch regressions:
```zig
comptime {
    if (@sizeOf(tracks.State) > 512 * 1024) {
        @compileError(std.fmt.comptimePrint(
            "tracks.State exceeds 512KB: {} bytes", .{@sizeOf(tracks.State)}
        ));
    }
}
```

## Build mode affects stack usage significantly

Test with different optimization levels—**Debug builds create substantially larger stack frames** due to disabled optimizations and debug metadata:

| Mode | Stack Impact | Notes |
|------|-------------|-------|
| Debug | Largest | No optimizations, full safety checks |
| ReleaseSafe | Medium | Optimized with safety checks retained |
| ReleaseFast | Smallest | Aggressive optimization, minimal checks |

Run `zig build -Doptimize=ReleaseSafe` to potentially reduce stack frame sizes, though this alone won't solve a 6-7MB allocation problem.

## Detecting and handling constrained startup states

REAPER's timer callbacks fire during startup, potentially while modal dialogs are active. Implement defensive checks:

```zig
export fn processTimerCallback() callconv(.C) void {
    // Skip processing during project load/save
    if (GetCurrentProjectInLoadSave() != null) return;
    
    // Skip if main window disabled (modal dialog active)
    const main = GetMainHwnd();
    if (main == null or IsWindowEnabled(main) == 0) return;
    
    // Safe to proceed
    const state = g_state orelse return;
    doProcessing(state);
}
```

REAPER 7.53+ (December 2025) added internal protections: "do not run FX-related timers/etc until load has completed." However, your timer callback may still fire during other modal states.

## Architecture patterns for stack-constrained callbacks

### The flag-and-defer pattern

Keep timer callbacks minimal—set flags and defer actual work:

```zig
var work_pending = std.atomic.Value(bool).init(false);

export fn processTimerCallback() callconv(.C) void {
    work_pending.store(true, .release);
}

// In main idle loop or control surface Run()
fn handlePendingWork() void {
    if (work_pending.swap(false, .acquire)) {
        const state = getGlobalState();
        doProcessing(state);
    }
}
```

### Use IReaperControlSurface instead of raw timers

The SWS extension demonstrates using a "fake control surface" for more reliable periodic callbacks:

```zig
// Control surfaces get Run() called ~30x/sec
// More robust than raw timer registration
const SWSTimeSlice = extern struct {
    pub fn Run(self: *SWSTimeSlice) callconv(.C) void {
        handlePendingWork();
    }
    // ... other IReaperControlSurface methods
};
```

### Incremental processing state machine

For unavoidably large operations, break work into chunks:

```zig
const ProcessState = enum { idle, polling_tracks, polling_items, syncing };
var process_state: ProcessState = .idle;
var current_track: u32 = 0;

fn incrementalProcess(state: *State) void {
    switch (process_state) {
        .idle => if (work_pending.load(.acquire)) {
            process_state = .polling_tracks;
            current_track = 0;
        },
        .polling_tracks => {
            // Process 10 tracks per callback
            const end = @min(current_track + 10, state.track_count);
            while (current_track < end) : (current_track += 1) {
                pollTrack(state, current_track);
            }
            if (current_track >= state.track_count) {
                process_state = .polling_items;
            }
        },
        // ... continue through states
    }
}
```

## macOS-specific escape mechanisms

### dispatch_source timer provides fresh stack context

Replace REAPER's timer callback with a GCD dispatch source—handlers run on the main queue with a clean stack frame:

```zig
// From Zig, you'd call these through C interop
// dispatch_source handlers run with full main thread stack available

const timer = dispatch_source_create(
    DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue()
);
dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
dispatch_source_set_event_handler(timer, handler_block);
dispatch_resume(timer);
```

**Critical caveat**: `dispatch_async` to main queue doesn't work inside modal windows—when `[NSApp runModalForWindow:]` creates its own run loop, dispatched blocks won't execute. Use `performSelectorOnMainThread:waitUntilDone:NO` as a fallback.

### Query remaining stack at runtime

For debugging, detect available stack space:

```c
#include <pthread.h>

size_t get_remaining_stack() {
    pthread_t self = pthread_self();
    void* stack_addr = pthread_get_stackaddr_np(self);
    size_t stack_size = pthread_get_stacksize_np(self);
    void* stack_bottom = (char*)stack_addr - stack_size;
    
    volatile char marker;
    return (size_t)((char*)&marker - (char*)stack_bottom);
}
```

Call this at callback entry to log warnings when stack drops below a threshold (e.g., 1MB remaining).

## Recommended implementation strategy

1. **Immediate fix**: Move all State structs to static storage using the `const S = struct { var ... }` pattern
2. **Add compile-time size assertions** to catch future regressions  
3. **Implement startup guards** checking `GetCurrentProjectInLoadSave()` and `IsWindowEnabled(GetMainHwnd())`
4. **Consider IReaperControlSurface** for periodic work instead of raw timer registration
5. **Test both launch methods** explicitly during development

The core insight is that **Zig's stack allocation model is incompatible with multi-megabyte local variables**, regardless of whether they're actually used. Moving to heap or static storage is not an optimization—it's the only viable architecture for large state in callback-driven plugins.

## Debugging checklist

- Run `vmmap <pid> | grep -i stack` to see actual stack regions
- Check crash reports in `~/Library/Logs/DiagnosticReports/` for stack addresses near the 8MB limit
- Use `lldb` with `bt` to verify frame depth during problematic states
- Build with ReleaseSafe to reduce baseline stack usage
- Add `@compileLog("State size:", @sizeOf(State))` to track struct sizes during development
