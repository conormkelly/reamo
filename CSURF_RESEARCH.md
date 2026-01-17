# REAPER control surface state sync: callbacks, polling, and practical patterns

REAPER's CSurf implementations universally use **hybrid callback + polling architectures**—pure callback approaches are insufficient because REAPER's callback system has known gaps. Developer consensus from Cockos forums is clear: "You probably don't want to use callbacks only... not everything results in a callback, so it's better to poll for state changes." The SWS Extension demonstrates the canonical pattern: set dirty flags in callbacks, then process batched changes in the ~27ms `Run()` tick.

## Production CSurf implementations are fundamentally hybrid

MCU and HUI protocols are **push-based at the protocol level**—MIDI has no query mechanism—but the DAW-side implementations still poll internally. REAPER's built-in control surface code uses callbacks (`SetSurfaceVolume`, `SetSurfacePan`, etc.) to react to state changes pushed from REAPER, but relies on `Run()` at **~37Hz** (configurable via "Control surface display update frequency") for:

- Reading incoming MIDI messages from hardware
- Updating displays, scribble strips, and meters  
- Sending feedback to physical controllers
- Polling continuous data like playhead position

The SWS Extension implements a "fake" control surface (`SWSTimeSlice`) that registers empty identification strings to hide from the UI while leveraging the callback infrastructure:

```cpp
class SWSTimeSlice : public IReaperControlSurface {
    const char *GetTypeString() { return ""; }  // Empty to hide from UI
    bool m_bChanged;
    
    void SetTrackListChange() {
        m_bChanged = true;  // Flag for batch processing
        SNM_CSurfSetTrackListChange();
    }
    
    void Run() {
        SNM_CSurfRun();  // ~27ms tick
        if (m_bChanged) {
            m_bChanged = false;
            ScheduleTracklistUpdate();
        }
    }
};
```

## Documented callback gaps explain why polling is necessary

REAPER's CSurf callbacks have **known reliability issues** that experienced developers have catalogued. The SWS Extension source contains explicit warnings:

**`OnTrackSelection()` is unreliable** with three documented problems: it doesn't fire if the Mixer option "Scroll view when tracks activated" is disabled, it gets called *before* `CSURF_EXT_SETLASTTOUCHEDTRACK`, and critically—it only fires for mouse clicks in TCP/MCP, not for action-based or API-based selection.

**`CSURF_EXT_SETFXCHANGE` has edge cases**: it doesn't fire when dragging FX between tracks, fires multiple times (once per FX) when switching projects, and in older REAPER versions didn't supply the `MediaTrack*` parameter at all.

**Project tab switching** only triggers `SetTrackListChange()`—the same callback as track add/remove/reorder—requiring developers to maintain project pointer comparisons to distinguish these cases.

**Undo/redo has no dedicated callback**. Since undo can restore any previous state (track order, FX chains, all parameters), developers must detect this through state comparison or polling.

Xenakios (prominent extension developer) stated this directly: "There's in fact a frustrating lack of callbacks/event notifications in the Reaper extension plugins system. You will realize IReaperControlSurface will not be able to handle everything you might want to get notified about."

## Threading model provides clear guarantees

All CSurf callbacks and timer callbacks run on **REAPER's main/UI thread**—this is a hard guarantee. The SWS Extension's `ScheduledJob` system explicitly documents polling "from the main thread via SNM_CSurfRun()". Callbacks cannot interrupt each other mid-execution; REAPER processes them sequentially within the main thread's event loop.

The canonical pattern exploits this guarantee: callbacks set flags atomically, then `Run()` processes accumulated state changes:

```cpp
void SetSurfaceMute(MediaTrack *tr, bool mute) { 
    m_dirtyFlags |= DIRTY_MUTE;  // Safe: same thread as Run()
}

void Run() {
    if (m_dirtyFlags & DIRTY_MUTE) {
        ProcessMuteChanges();
        m_dirtyFlags &= ~DIRTY_MUTE;
    }
}
```

This eliminates race conditions entirely. If you need background threads for I/O (network, device communication), you must synchronize back to the main thread before calling any REAPER API functions—most API calls are **not thread-safe**.

## Acceptable staleness varies dramatically by data type

Industry standards for DAW control surfaces establish clear latency tolerances:

| Data Type | Acceptable Latency | Professional Target |
|-----------|-------------------|---------------------|
| Fader/volume feedback | 36–64ms | <10ms |
| Visual meter updates | <100ms | <50ms |
| Selection state | 100–200ms | <100ms |
| FX parameter changes | 36–64ms | <10ms |
| Connection health heartbeat | 2–5 seconds | — |

A **2-second safety poll is appropriate for drift detection and connection health**, but far too slow for primary UI synchronization. The Mixxx documentation explicitly notes that 36–64ms latency "is acceptable if using a keyboard/mouse or MIDI controller"—users perceive latency above ~100ms as broken.

For primary state sync, target **30Hz minimum** (~33ms), matching REAPER's default control surface update frequency. The SWS Extension uses `#define SNM_CSURF_RUN_TICK_MS 27.0` as their measured average.

## Hash-based change detection is negligibly cheap

Wyhash (or similar fast hashes) computing **150-byte structs at 30Hz is essentially free**. Benchmarks show Wyhash achieving ~540 million hashes/second for small inputs. Your 4,500 hashes/second requirement represents **0.0008% utilization**—roughly 8 microseconds total CPU time per second.

Compare this to REAPER API call overhead: each `GetTrackState*` call involves function pointer lookup through the extension API table, internal state access, and potential locking—typically **100ns–10μs per call**. Hash comparison runs at ~2ns. This means hash verification is 10–100x cheaper than redundant API calls.

The performance tradeoff clearly favors hash-based verification:

```cpp
// Negligible: ~2ns
if (current_hash != cached_hash) {
    // Only call expensive APIs when state actually changed
    RefreshFromReaper();  // ~100μs+ of API calls
    cached_hash = current_hash;
}
```

## Dirty-flag architecture with hash verification is optimal

For systems trusting dirty flags as the primary change signal, the **2-second safety poll should both compare state AND log drift**:

```cpp
void SafetyPoll() {  // Every 2 seconds
    uint64_t computed_hash = wyhash(¤t_state, sizeof(current_state));
    
    if (computed_hash != last_known_clean_hash) {
        if (!any_dirty_flags_set) {
            // Drift detected without dirty flag—this is a bug or missed callback
            LogDrift("State changed without dirty flag", 
                     last_known_clean_hash, computed_hash);
        }
        // Force refresh regardless
        MarkAllDirty();
        last_known_clean_hash = computed_hash;
    }
}
```

The debugging value is significant: drift logs identify which callbacks you're missing, revealing undocumented REAPER behaviors or bugs in your dirty-flag management. During development, enable verbose logging; in production, you can reduce to metrics-only.

## SWS and community patterns worth adopting

**Deferred asynchronous processing** handles edge cases where callback data is incomplete:

```cpp
// From SWS: "Preventing any possible edge cases where not all track data 
// was set when the first CSURF_EXT_SETFXCHANGE notification is sent"
void SetTrackListChange() {
    m_bAutoColorTrackAsync = true;  // Process on NEXT tick, not immediately
}
```

**Ignore counters** suppress redundant callbacks:

```cpp
// SetTrackTitle fires NumTracks+1 times per SetTrackListChange
void SetTrackTitle(MediaTrack *tr, const char *c) {
    if (!m_iACIgnore) {
        ProcessTitleChange();
    } else {
        m_iACIgnore--;  // Countdown to ignore expected duplicates
    }
}
```

**Control Surface Integrator (CSI)** and **ReaLearn** are well-maintained open-source projects with extensive forum threads documenting their architectural decisions. CSI's 750+ page forum thread is a goldmine for edge cases. Both emphasize "controller should be dumb"—let REAPER be the source of truth, use feedback to update controller state rather than maintaining independent state.

## Key resources for implementation

The **SWS Extension source** (github.com/reaper-oss/sws) contains the most production-tested patterns. Key files: `sws_extension.cpp` for the fake CSurf pattern, `SnM/SnM.h` for timing constants, `Breeder/BR.cpp` for `Extended()` callback handling.

The **REAPER SDK** (github.com/justinfrankel/reaper-sdk) includes `reaper_plugin.h` with all `CSURF_EXT_*` constants. The SDK README warns these are "not to be used as models for well-designed plug-ins" but they demonstrate REAPER's expectations.

**forum.cockos.com** threads to study: "Control Surface Plugin Guide" (t=167139) for Xenakios's callback limitations discussion, "Reaper API: request for FX list change notification" (t=99616) for schwa's official `Extended()` documentation, and the Control Surface Integrator thread (t=183143) for real-world implementation war stories.

## Conclusion

The optimal architecture is **callback-primary with polling safety net**: trust `SetSurface*` and `Extended()` callbacks for immediate response, process changes in `Run()` using dirty flags to batch updates, and run a 2-second hash-based safety poll to catch drift and log debugging information. Hash computation overhead is negligible compared to API calls. All callbacks execute on the main thread with no interruption concerns. Plan for `OnTrackSelection()`, project switching, and undo/redo as known callback gaps requiring explicit handling.
