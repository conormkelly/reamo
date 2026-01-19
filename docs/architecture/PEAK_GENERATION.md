# Solving the ARM64 macOS GetMediaItemTake_Peaks Bug in REAPER Extensions

**The issue you're experiencing is likely caused by Apple's non-standard ARM64 calling convention, specifically parameter alignment differences when function pointers are cast via GetFunc().** This explains why Lua works (direct binding) while C/Zig fails (requires pointer casting). The most reliable workaround is switching to the AudioAccessor API, which SWS Extension also uses, or implementing a Lua bridge for peak retrieval.

## The root cause: Apple's ARM64 ABI differs from standard

Apple's ARM64 macOS uses a **non-standard parameter alignment convention** that breaks function pointer casting. While standard AAPCS64 (used on Linux/Windows ARM64) aligns all stack parameters to 8 bytes, Apple's ABI aligns parameters to their natural size—`int` at 4 bytes, `double` at 8 bytes. When GetFunc() returns a `void*` that gets cast to the expected function signature, any subtle mismatch causes parameters to be read from **wrong stack positions**.

This explains your symptom pattern precisely. With low peakrate (**0.02**) and starttime at exact item position (**0.0**), the parameter values happen to survive misalignment—small floating-point values can produce "acceptable" garbage when misinterpreted. With high peakrate (**400.0**) and offset starttime, the bit patterns produce values that fail internal validation or cause the function to return 0 peaks.

The official REAPER SDK's `reaper_plugin_functions.h` defines:

```c
int (*GetMediaItemTake_Peaks)(MediaItem_Take* take, double peakrate, 
    double starttime, int numchannels, int numsamplesperchannel, 
    int want_extra_type, double* buf);
```

If your cast signature differs even slightly—different const-ness, struct packing, or if the internal implementation uses variadic arguments—ARM64 macOS will misroute parameters while x86_64 and Lua bindings work correctly.

## AudioAccessor: the proven reliable alternative

SWS Extension—the most battle-tested REAPER extension—**does not use GetMediaItemTake_Peaks** for its peak analysis functions. Instead, SWS uses **GetAudioAccessorSamples()** to read raw audio samples, then computes peaks manually. This approach is documented in `Breeder/BR_Loudness.cpp`:

```cpp
GetAudioAccessorSamples(data.audio, data.samplerate, data.channels, 
    currentTime, sampleCount, &samples[0]);
```

The AudioAccessor API bypasses the peak cache entirely and reads directly from source audio. Key characteristics for your tile-based system:

- **Reliability**: No casting issues since it's a cleaner API surface
- **Flexibility**: Request any sample rate—use **2000-4000 Hz** for efficient peak computation rather than full 44.1kHz
- **Performance tradeoff**: Slower than cached peaks, but predictable
- **Main thread requirement**: Create/destroy accessors on main thread only

For your 0.5-second tiles at LOD 2 (**200 peaks**), request approximately 22,050 samples at source rate, then compute min/max in pairs of ~110 samples each. CPU overhead is modest—O(n) scan of the sample buffer.

```c
AudioAccessor* acc = CreateTakeAudioAccessor(take);
double buf[22050];
GetAudioAccessorSamples(acc, 44100, 1, starttime, 22050, buf);
// Compute peaks from buf
DestroyAudioAccessor(acc);
```

## Direct .reapeaks file access as a bypass option

REAPER's peak cache format is fully documented and can be read directly, bypassing API issues entirely. The format uses a header followed by multiple mipmaps:

| Header Field | Size | Description |
|--------------|------|-------------|
| Magic | 4 bytes | "RPKN" (v1.1) or "RPKL" (v1.2 for float audio) |
| Channels | 1 byte | Number of audio channels |
| Mipmap count | 1 byte | Number of resolution levels (max 16) |
| Sample rate | 4 bytes | Source audio sample rate |

Each mipmap contains a division factor (samples per peak) and peak data as 16-bit signed pairs (max, min) per channel. Default mipmaps in REAPER 7.x provide **~400 peaks/sec**, **~10 peaks/sec**, and **~1 peak/sec**.

For floating-point audio (RPKL format), values -24576 to +24576 map linearly to -1.0 to +1.0, with logarithmic encoding beyond that range.

Peak files live at `GetPeakFileName(source)` or `GetPeakFileNameEx()` with extension `.reapeaks`.

## Practical workaround strategies ranked by reliability

**Strategy 1: Lua bridge with file-based IPC (most reliable)**

Lua's direct REAPER bindings work correctly. Create a Lua script that handles peak retrieval and communicates results via file:

```lua
-- Lua side: write peaks to file
local peaks = reaper.GetMediaItemTake_Peaks(take, 400.0, starttime, 2, 200, 0, buf)
write_json_file(peaks_data, "/tmp/reaper_peaks.json")
```

ExtState has a practical limit around **4KB** and cannot contain newlines (they get truncated). For peak data in the **KB-MB range**, file-based IPC is faster and more reliable. Poll the file from your extension or use filesystem watchers.

**Strategy 2: Full-item fetch then server-side slicing**

If GetMediaItemTake_Peaks works with starttime at item start (0.0 offset), fetch all peaks at once and slice in your server code:

```c
// Fetch full item at 400 peaks/sec
int count = duration * 400;
double* full_peaks = malloc(count * 2 * sizeof(double));
GetMediaItemTake_Peaks(take, 400.0, item_position, 2, count, 0, full_peaks);
// Slice for each tile request
```

The **num_peaks limit** is effectively memory-bound—a 1-hour stereo file at 400 peaks/sec needs only **~11.5 MB** of peak data.

**Strategy 3: AudioAccessor with caching layer**

Implement the AudioAccessor approach with aggressive caching:

```c
// Create once per item, reuse across tiles
static AudioAccessor* cached_accessor = NULL;
static MediaItem_Take* cached_take = NULL;

if (take != cached_take) {
    if (cached_accessor) DestroyAudioAccessor(cached_accessor);
    cached_accessor = CreateTakeAudioAccessor(take);
    cached_take = take;
}
GetAudioAccessorSamples(cached_accessor, ...);
```

## Fixing the GetFunc() issue directly

If you want to continue using GetMediaItemTake_Peaks via GetFunc(), try these debugging steps:

**1. Use REAPERAPI_LoadAPI() instead of manual casting**

```c
#define REAPERAPI_IMPLEMENT
#include "reaper_plugin_functions.h"

// In plugin init:
REAPERAPI_LoadAPI(rec->GetFunc);

// Then call directly:
int result = GetMediaItemTake_Peaks(take, 400.0, starttime, 2, 200, 0, buf);
```

This uses the SDK's verified signatures rather than manual casts.

**2. Enable compiler warnings for function pointer mismatches**

```
-Wcast-function-type -Wincompatible-function-pointer-types
```

**3. Test under Rosetta 2**

Run your extension in x86_64 mode via Rosetta to confirm the issue is ARM64-specific. If it works under Rosetta, the calling convention hypothesis is confirmed.

**4. Report to Cockos forums**

This specific issue (high peakrate + offset failing on ARM64 via GetFunc but working in Lua) is **not documented** in any forum threads or GitHub issues. A minimal reproduction case would help Cockos identify whether this is a REAPER bug or expected behavior.

## Optimal caching architecture for web-based DAW

For your tile-based web interface with long audio items, implement a **multi-resolution mipmap cache**:

| Level | Resolution | Storage per hour (stereo) | Use case |
|-------|------------|---------------------------|----------|
| 0 | 1000 peaks/sec | ~28 MB | Full zoom |
| 1 | 100 peaks/sec | ~2.8 MB | Medium zoom |
| 2 | 10 peaks/sec | ~288 KB | Overview |
| 3 | 1 peak/sec | ~29 KB | Extreme overview |

**Load Level 3 immediately** (~29KB/hour)—this is always-resident data for instant overview rendering. **Lazy-load higher resolutions** on demand based on viewport zoom level. For items exceeding 1 hour, use **tile-based loading** with 5-10 second tiles and LRU eviction.

The BBC's **Peaks.js/audiowaveform** ecosystem uses exactly this pattern for web-based waveform visualization. Their binary `.dat` format uses 8-bit resolution (sufficient for display) and client-side resampling.

## Conclusion

The GetMediaItemTake_Peaks failure is almost certainly an ARM64 macOS calling convention issue triggered by function pointer casting via GetFunc(). Your immediate options are:

1. **Switch to AudioAccessor API** (SWS's proven approach)
2. **Implement Lua bridge** with file-based IPC for peak data transfer
3. **Read .reapeaks files directly** to bypass the API entirely
4. **Use REAPERAPI_LoadAPI()** instead of manual GetFunc() casting

For production reliability, AudioAccessor combined with a multi-resolution caching layer offers the best tradeoff between reliability and performance. The slight CPU overhead of computing peaks from samples is preferable to debugging platform-specific calling convention issues.
