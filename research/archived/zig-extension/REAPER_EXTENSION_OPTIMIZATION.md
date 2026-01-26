# Optimizing a Zig-based REAPER extension for WebSocket control

Your **240 MB memory overhead** with a Zig-based WebSocket extension is significantly higher than typical REAPER extensions, which suggests opportunities for optimization beyond the extension itself—most REAPER plugins operate with minimal idle memory. The core answer to your optimization questions: unused function pointers via `rec->GetFunc` add only **8 bytes each** (NULL pointers on 64-bit), timer callbacks should run at **~30 Hz**, and Zig's `ReleaseSmall` with stripping can reduce binary size by **2-10x** versus `ReleaseFast`.

## Function pointers are cheap, but declarations aren't

Calling `rec->GetFunc("function_name")` for an unused function simply returns NULL—no additional memory is allocated, no code is linked. The cost is just **8 bytes per pointer variable** on 64-bit systems. However, *declaring* function pointer types in your source code does have implications.

The REAPER SDK provides `REAPERAPI_MINIMAL` mode specifically to address binary bloat. Without it, including `reaper_plugin_functions.h` compiles in declarations for all **~1,000+ API functions**. The recommended pattern is explicit opt-in:

```zig
// Zig equivalent: only import functions you actually use
const GetFunc = rec.GetFunc orelse return 0;
const ShowConsoleMsg = @ptrCast(?fn([*c]const u8) callconv(.C) void, GetFunc("ShowConsoleMsg"));
const Main_OnCommand = @ptrCast(?fn(c_int, c_int) callconv(.C) void, GetFunc("Main_OnCommand"));
```

For production REAPER extensions, the SWS codebase explicitly warns against expensive API patterns. Their source comments flag `CountMediaItems` as **O(N)** and `CountSelectedMediaItems` as **O(MN)**—both marked "should be banned from the extension" for use in loops. Cache results instead of polling these repeatedly.

## Memory overhead likely stems from your WebSocket stack

The **240 MB** figure is unusually high for a REAPER extension. SWS, with hundreds of features, runs with minimal idle overhead (~2-4 MB binary, negligible runtime memory). ReaPack uses SQLite for package management and remains lightweight. Your memory consumption almost certainly comes from the WebSocket implementation, Zig's standard library allocations, or thread stacks—not REAPER API usage.

Memory-efficient patterns from major extensions include:

- **Lazy initialization**: SWS initializes features only when first accessed
- **Deferred UI updates**: Batched via `plugin_register("timer", ...)` rather than immediate
- **Paired alloc/free APIs**: SWS exposes functions like `FNG_AllocMidiTake`/`FNG_FreeMidiTake` with explicit ownership
- **WDL containers**: `WDL_FastString`, `WDL_PtrList`, `WDL_TypedBuf` for efficient memory reuse

For Zig, consider using `std.heap.GeneralPurposeAllocator` with arena patterns for request-scoped allocations, and ensure your WebSocket library isn't holding large buffers indefinitely. Your 5 threads are reasonable for a WebSocket server, but verify each thread's stack size (default 8 MB on many platforms could account for 40 MB alone).

The `plugin_register` overhead is negligible—registration is a one-time cost. The *ongoing* cost depends on callback frequency. Hook callbacks (`hookcommand`, `hookcommand2`) fire on every action and must be extremely fast. Timer callbacks run at ~30 Hz.

## Timer frequency and the polling vs push tradeoff

REAPER's control surface `Run()` method is called approximately **30 times per second** (~33 ms interval), tied to the "Control surface display update frequency" preference. This is your polling budget.

For a WebSocket API extension, the critical insight is using **push-based updates via `csurf_inst`** rather than polling in `Run()`. When you register a control surface instance with `plugin_register("csurf_inst", instance)`, REAPER calls your virtual methods whenever state changes:

```cpp
// Push callbacks - REAPER calls these when state changes:
virtual void SetSurfaceVolume(MediaTrack *track, double volume) { }
virtual void SetPlayState(bool play, bool pause, bool rec) { }
virtual void SetSurfaceMute(MediaTrack *track, bool mute) { }
virtual void OnTrackSelection(MediaTrack *track) { }
// Extended notifications for FX, markers, etc:
virtual int Extended(int call, void *parm1, void *parm2, void *parm3) { }
```

The `Extended()` method receives `CSURF_EXT_*` notifications: `CSURF_EXT_SETFXPARAM` for parameter changes, `CSURF_EXT_SETPROJECTMARKERCHANGE` for markers, and others. This eliminates polling overhead for most state changes—your extension only processes actual updates.

**Important `Main_OnCommand` gotchas**: Always guard against recursion when calling `Main_OnCommand` from hook callbacks. Use `NamedCommandLookup("_ACTION_NAME")` for custom actions since numeric command IDs can change between sessions. Most API functions must be called from the main thread only.

## Zig build configuration for minimal dylibs

`ReleaseSmall` versus `ReleaseFast` makes a significant difference—real-world measurements show **2-10x smaller binaries** with `ReleaseSmall`. For a REAPER extension where CPU usage is already negligible, `ReleaseSmall` is likely the better choice. Combined with stripping, simple extensions can achieve sub-100 KB sizes.

**Recommended build.zig for macOS:**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    
    const lib = b.addSharedLibrary(.{
        .name = "reaper_wsapi",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,  // Strip in release modes
    });
    
    lib.linkLibC();  // Required for REAPER C API interop
    lib.addIncludePath(b.path("reaper-sdk/sdk"));
    
    b.installArtifact(lib);
}
```

Zig enables **LTO by default** for release builds—no manual configuration needed. The key settings are:

| Setting | Development | Production |
|---------|-------------|------------|
| Optimize | `.Debug` | `.ReleaseSmall` or `.ReleaseFast` |
| Strip | `false` | `true` |
| LTO | automatic | automatic |

**Critical macOS considerations**: Build separate binaries for x86_64 and aarch64 (Apple Silicon). REAPER won't load architecture-mismatched dylibs. Install to `~/Library/Application Support/REAPER/UserPlugins/` with naming convention `reaper_<name>.dylib`.

For C++ extensions using WDL on macOS, the required flags include `-DSWELL_PROVIDED_BY_APP` (REAPER provides SWELL) and linking against `swell-modstub.mm`. For pure Zig, ensure exported functions use `export fn` and `callconv(.C)`.

## Conclusion

Your 240 MB memory footprint warrants investigation outside the REAPER API layer—examine your WebSocket library's buffer management, thread stack sizes, and whether you're holding references unnecessarily. The REAPER SDK itself is remarkably lightweight by design.

For immediate wins: use `REAPERAPI_MINIMAL` patterns (only import functions you call), implement `IReaperControlSurface` push callbacks instead of polling, build with `ReleaseSmall` and `.strip = true`, and cache expensive API results like track counts. The ~30 Hz timer frequency is appropriate for control surface updates—don't poll faster than REAPER's own refresh rate.
