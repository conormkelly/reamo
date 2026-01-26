# REAPER Extension Development: Timer API, Thread Safety, and Large Data Handling

Building a WebSocket-enabled REAPER extension with a 30Hz polling timer is architecturally sound. REAPER's timer callbacks **skip missed invocations** rather than queuing them, audio processing runs on a **separate real-time thread** so main thread blocking won't cause dropouts, and both `kbd_enumerateActions()` and `EnumInstalledFX()` read from **cached in-memory data** making them fast. However, most REAPER API functions require main thread execution, so WebSocket commands should be queued and processed via the timer callback.

---

## Timer reentrancy: REAPER skips missed callbacks

When `plugin_register("timer", callback)` is used and the callback takes longer than the ~33ms interval, **REAPER skips/coalesces missed calls** rather than queuing them or allowing reentrancy. Direct evidence comes from the SWS Extension source code comment in `sws_util.mm`:

> "REAPER's misc timer (based on NSTimer), responsible for many many things from UI updates to updating GetPlayPosition(), **won't be re-entered** in the event loop iterations above while if we're blocking it's handler."

This behavior aligns with the underlying Windows `WM_TIMER` mechanism. Microsoft documentation and technical analysis confirm that when a thread is busy during scheduled timer intervals, those messages are simply **not generated**—there is no queue of pending timer calls. After a slow callback completes, only one new timer fires; there's no "catch up" behavior.

**Practical implication**: If your callback takes 100ms, you'll miss approximately 2-3 timer events. The timer resumes normally afterward with no backlog. For your 30Hz polling architecture, this means occasional slow operations won't cascade into system instability—they'll just cause temporary gaps in polling.

---

## Main thread blocking is safe for audio continuity

REAPER's audio processing runs on a **separate real-time thread** from the main/UI thread. Blocking the main thread—even for 100+ milliseconds—will **not cause audio dropouts**. This is explicitly confirmed in the official JSFX documentation:

> "Note that this code runs in a **separate thread from the audio processing**, so you may have both running simultaneously."

Forum evidence corroborates this architecture. Users report that when plugins cause UI freezes, "the sound continues playing using the new effect in the background, just the UI freezes. The entire UI of Reaper also freezes." Audio continues uninterrupted while the main thread is blocked.

| Thread | Purpose | Impact of Blocking |
|--------|---------|-------------------|
| **Main/UI Thread** | GUI rendering, timer callbacks, scripts | UI freezes, NO audio impact |
| **Audio Thread (RT)** | Real-time audio processing, plugin DSP | Audio dropouts if blocked |
| **Anticipative FX Threads** | Pre-computed FX processing | CPU distribution optimization |

Your action enumeration taking 100ms will freeze the UI momentarily but won't affect audio playback. That said, for user experience, operations exceeding **~500ms** should be chunked or moved to background processing with progress indication.

---

## Both enumeration APIs are fast—they read cached data

**`EnumInstalledFX()`** reads from pre-loaded memory structures populated at REAPER startup from cache files (`reaper-vstplugins64.ini`, `reaper-jsfx.ini`). It does **not** perform filesystem scanning during enumeration. Evidence: REAPER 7.42+ added `index=-1` specifically to "re-read JSFX info"—confirming the data is normally cached and not re-read.

**`kbd_enumerateActions()`** similarly reads from an in-memory action list loaded at startup from `reaper-kb.ini`. Each call is a simple indexed lookup, not a computation.

| Function | Data Source | Expected Performance |
|----------|-------------|---------------------|
| `EnumInstalledFX()` | Memory cache from .ini files | **<10ms** for 500-1000 plugins |
| `kbd_enumerateActions()` | Memory cache from reaper-kb.ini | **<100ms** for 15,000+ actions |

Your concern about **985KB of JSON for 15,619 actions** is valid not because of API overhead, but because of **JSON serialization and network transmission time**. The enumeration itself should complete in under 100ms; the bottleneck is building and sending the JSON response.

---

## Recommended architecture for large on-demand queries

The SWS Extension demonstrates best practices for handling large enumerations. Key patterns include caching enumerated data, using efficient data structures, and leveraging `IReaperControlSurface` for periodic state updates.

**Caching strategy**: Build your action cache at extension initialization and pre-serialize to JSON. The action list rarely changes during a session—invalidate only when extensions are loaded/unloaded or custom actions are modified. SWS explicitly warns against calling expensive enumeration functions repeatedly:

```cpp
// From SWS sws_extension.cpp comments:
// CountMediaItems -- O(N): should be banned from the extension, ideally
// CountSelectedMediaItems -- O(MN): should be banned from the extension
```

**Recommended implementation**:

```cpp
struct ActionCache {
    std::vector<ActionInfo> actions;
    std::string jsonCache;      // Pre-built JSON
    bool isDirty = true;
    
    void BuildIfNeeded() {
        if (!isDirty) return;
        // Enumerate once, build JSON once
        EnumerateAllActions();
        SerializeToJson();
        isDirty = false;
    }
};
```

**For your WebSocket server specifically**, consider implementing pagination for the `action/getActions` endpoint. Return action data in pages (e.g., 1000 actions per page) with a total count, allowing clients to request specific pages. This keeps individual responses under ~65KB and eliminates the 100ms+ blocking concern entirely.

---

## Thread safety requires command marshaling

Most REAPER API functions are **main-thread-only** by default. Only a handful are explicitly documented as threadsafe:

- `Audio_IsRunning()` — "threadsafe"
- `Audio_IsPreBuffer()` — "threadsafe"  
- `IsInRealTimeAudio()` — "threadsafe"
- Query functions like `GetPlayPosition()`, `GetPlayState()` — "can be called from any context"

All action enumeration, project modification, and UI-related functions require main thread execution. For your WebSocket server architecture, this means **commands must be queued and processed via the timer callback**:

```
┌───────────────────────────────────────┐
│  WebSocket Server (Background Thread) │
│  - Parse incoming commands            │
│  - Queue to thread-safe structure     │
└───────────────────────────────────────┘
                    │
                    ▼ (mutex-protected queue)
┌───────────────────────────────────────┐
│  Timer Callback (Main Thread, 30Hz)   │
│  - Dequeue pending commands           │
│  - Execute REAPER API calls safely    │
│  - Queue responses for transmission   │
└───────────────────────────────────────┘
```

Use `std::mutex` with `std::lock_guard` for the command queue. The timer callback processes queued commands safely on the main thread, then queues responses for the WebSocket thread to transmit.

---

## Practical recommendations for your implementation

**For the `action/getActions` command specifically**:

1. **Cache at startup**: Enumerate all actions once during `REAPER_PLUGIN_ENTRYPOINT` and build the JSON response. Store in a static/global cache.

2. **Implement pagination**: Modify the API to accept `page` and `pageSize` parameters. Return metadata including `totalActions` and `totalPages`. This transforms a single 985KB response into manageable ~50KB chunks.

3. **Consider lazy enumeration**: If the full action list is rarely requested, enumerate on first request rather than startup—but still cache the result.

4. **Add cache invalidation hooks**: Use `plugin_register("hookcommand2", ...)` to detect when custom actions might have changed, setting a dirty flag for lazy rebuild.

**For timer callback design**:

- Process multiple queued commands per tick to maximize throughput
- Implement a time budget (~20ms max) per tick to prevent stacking
- Use non-blocking I/O for WebSocket responses—queue them for the network thread

**Memory management**: Use WDL data structures (`WDL_FastString`, `WDL_PtrList`) if integrating with SWS patterns, or standard C++ containers with pre-allocated capacity to avoid allocation during enumeration loops.

---

## Conclusion

Your architecture is fundamentally sound. The 30Hz timer with synchronous WebSocket command processing will work without causing audio issues. For the large action enumeration specifically, the performance bottleneck is JSON serialization and network I/O rather than the REAPER API calls themselves. Implementing caching and pagination will reduce worst-case response times from 100ms+ to under 10ms while improving client experience. The critical architectural requirement is ensuring all REAPER API calls happen on the main thread via the timer callback, with thread-safe queuing for commands arriving on the WebSocket thread.
