# Zig FFI failure with REAPER's GetMediaItemTake_Peaks on ARM64 macOS

The **channel count mismatch** (1 in Zig vs 2 in Lua for `GetMediaSourceNumChannels`) is the critical clue—this indicates a fundamental ABI or pointer interpretation issue affecting multiple functions, not just `GetMediaItemTake_Peaks`. The root cause likely involves how Zig passes parameters to REAPER's C API function pointers on Apple Silicon, specifically affecting the take pointer or floating-point parameters.

## The prime suspect: function pointer type declarations

The most probable cause is **incorrect function pointer type declaration** in Zig. On ARM64 macOS, the calling convention for non-variadic C functions passes doubles in floating-point registers (**d0-d7**) and pointers/integers in general-purpose registers (**x0-x7**) independently. If Zig's function pointer declaration doesn't correctly specify parameter types, the ABI layer may place values in wrong registers.

For `GetMediaItemTake_Peaks` with this signature:
```c
int GetMediaItemTake_Peaks(MediaItem_Take* take, double peakrate, double starttime, 
                           int numchannels, int numsamplesperchannel, 
                           int want_extra_type, double* buf);
```

The correct ARM64 register allocation should be:
- `take` (pointer) → **x0**
- `peakrate` (f64) → **d0** 
- `starttime` (f64) → **d1**
- `numchannels` (i32) → **x1**
- `numsamplesperchannel` (i32) → **x2**
- `want_extra_type` (i32) → **x3**
- `buf` (pointer) → **x4**

If the Zig declaration treats doubles incorrectly or uses wrong integer types, parameters will land in wrong registers causing garbage values or zeros to be read by REAPER.

## Correct Zig function pointer declaration for this API

Based on cfillion's barebone example and ARM64 ABI requirements, the function pointer must specify `callconv(.C)` and use exact C-compatible types:

```zig
pub var GetMediaItemTake_Peaks: *const fn(
    take: ?*anyopaque,      // MediaItem_Take*
    peakrate: f64,          // double - must be f64, NOT c_double alias
    starttime: f64,         // double
    numchannels: c_int,     // int
    numsamplesperchannel: c_int,
    want_extra_type: c_int,
    buf: [*]f64,            // double* output buffer
) callconv(.C) c_int = undefined;
```

**Critical checks for your declaration:**
1. **`callconv(.C)` is mandatory** - without this, Zig uses its own calling convention
2. **Use `f64` for doubles** - ensure they're not accidentally `f32` or passed as integers
3. **Use `c_int` (not `i32`)** for int parameters - though on ARM64 these are identical, consistency matters
4. **Buffer type `[*]f64`** - many-item pointer is correct for C's `double*`

## Diagnosing the channel count discrepancy

The **GetMediaSourceNumChannels returning 1 vs 2** strongly suggests the take pointer itself is corrupted or misinterpreted. Verify your take acquisition:

```zig
// Getting the take pointer - check these steps
const item = GetSelectedMediaItem(proj, 0);  // Returns ?*anyopaque
if (item) |i| {
    const take = GetActiveTake(i);  // Returns ?*anyopaque
    if (take) |t| {
        // Validate before use
        const is_valid = ValidatePtr2(proj, t, "MediaItem_Take*");
        if (is_valid == 0) {
            // Take pointer is invalid!
        }
    }
}
```

If `ValidatePtr2` returns true but channel count is wrong, the function pointer declaration for `GetMediaSourceNumChannels` may also be incorrect.

## Apple Silicon ABI considerations

Apple's ARM64 ABI has **key differences from standard AAPCS64**:

- **Variadic functions**: All arguments after fixed parameters go directly to stack, not registers. This breaks many FFI libraries—ensure REAPER API functions are not inadvertently treated as variadic
- **Stack alignment**: Must be 16-byte aligned at call time (hardware-enforced)
- **Register x18**: Reserved by Apple, never use
- **Frame pointer x29**: Must always be valid

For non-variadic functions like `GetMediaItemTake_Peaks`, Apple and Linux ARM64 ABIs behave identically, so the issue is likely in Zig's interpretation of your function pointer declaration rather than platform-specific ABI quirks.

## REAPER API context requirements

`GetMediaItemTake_Peaks` should only be called from the **main thread**. Timer callbacks registered via `plugin_register("timer", ...)` run on the main thread, so this should not be the issue. However, verify that:

1. Peak files have been built for the media item
2. The `starttime` parameter is within the source's actual duration
3. The buffer is sized correctly: `numchannels × numsamplesperchannel × 2` doubles minimum

A return value of **0** specifically means zero samples were retrieved. The return value is bit-packed: lower 20 bits contain sample count, so `result & 0xFFFFF` extracts actual samples returned.

## Recommended debugging steps

**Step 1: Verify parameter values with LLDB**

Attach to REAPER and set a breakpoint:
```bash
lldb -p $(pgrep -x REAPER)
(lldb) breakpoint set -n GetMediaItemTake_Peaks
(lldb) continue
```

When hit, inspect registers:
```bash
(lldb) register read x0 x1 x2 x3 x4  # pointer/int params
(lldb) register read d0 d1           # double params (peakrate, starttime)
```

Compare these values when called from Lua vs Zig. If **d0/d1 contain garbage or zeros** in the Zig case but correct values from Lua, the function pointer declaration is wrong.

**Step 2: Create a minimal C shim for verification**

```c
// debug_shim.c - compile and load as separate extension
#include <stdio.h>

int debug_GetPeaks(void* take, double peakrate, double starttime,
                   int numch, int numsamp, int extra, double* buf) {
    fprintf(stderr, "DEBUG: take=%p rate=%.2f start=%.2f ch=%d samp=%d buf=%p\n",
            take, peakrate, starttime, numch, numsamp, buf);
    // Call real function here
    return GetMediaItemTake_Peaks(take, peakrate, starttime, numch, numsamp, extra, buf);
}
```

Call this from Zig instead of the direct function. If parameters appear correct in the debug output but the underlying call still fails, the issue is elsewhere.

**Step 3: Check for @ptrCast alignment issues**

When loading function pointers from `getFunc`, use both casts:
```zig
const raw_ptr = rec.getFunc.?("GetMediaItemTake_Peaks");
if (raw_ptr) |ptr| {
    GetMediaItemTake_Peaks = @ptrCast(@alignCast(ptr));
}
```

The `@alignCast` is important because `?*anyopaque` has alignment 1, but function pointers have alignment 4+.

**Step 4: Compare identical Lua test**

Create a Lua script that logs exact parameter values and calls the same API:
```lua
local take = reaper.GetActiveTake(reaper.GetSelectedMediaItem(0, 0))
local source = reaper.GetMediaItemTake_Source(take)
local channels = reaper.GetMediaSourceNumChannels(source)
reaper.ShowConsoleMsg("Lua channels: " .. channels .. "\n")

local buf = reaper.new_array(channels * 80 * 2)
local result = reaper.GetMediaItemTake_Peaks(take, 10.0, 1894.0, channels, 80, 0, buf)
reaper.ShowConsoleMsg("Lua result: " .. result .. "\n")
```

If this succeeds with channels=2 and Zig shows channels=1 for the same take, your take pointer acquisition is broken.

## Known Zig FFI issues on ARM64

Zig 0.12+ introduced a **breaking change** (Issue #19921): function pointers in extern contexts must explicitly specify `callconv(.C)`. If your extern struct contains function pointer fields without this annotation, they'll fail:

```zig
// WRONG - will error in Zig 0.12+
const SomeAPI = extern struct {
    callback: *const fn () void,  // Missing callconv
};

// CORRECT
const SomeAPI = extern struct {
    callback: *const fn () callconv(.C) void,
};
```

Additionally, **Issue #22689** reports a recent regression with pointer parameters in DynLib-loaded functions. If you're using Zig 0.15 specifically, check if this was fixed or use a workaround by linking libc explicitly.

## Most likely root causes ranked

1. **Function pointer missing `callconv(.C)`** - doubles would go to wrong registers
2. **Take pointer corrupted** during acquisition or casting - explains channel mismatch
3. **f64 parameters declared as wrong type** - e.g., accidentally using `c_longdouble` or integer type
4. **Buffer pointer alignment issue** - though less likely to cause return 0
5. **@ptrCast without @alignCast** when loading function pointer from getFunc

## Verification checklist

Before further debugging, verify each item:

- [ ] All REAPER API function pointers include `callconv(.C)`
- [ ] `f64` is used for double parameters (not f32 or any c_ alias)
- [ ] `c_int` is used for int parameters (not i32 directly)
- [ ] Function pointer loaded with `@ptrCast(@alignCast(...))`
- [ ] Take pointer validated with `ValidatePtr2` immediately before use
- [ ] Buffer allocated with correct size: `channels × samples × 2`
- [ ] `GetMediaSourceNumChannels` also uses correct function signature

The channel count discrepancy is your key diagnostic: fix whatever causes `GetMediaSourceNumChannels` to return different values, and `GetMediaItemTake_Peaks` will likely start working too.
