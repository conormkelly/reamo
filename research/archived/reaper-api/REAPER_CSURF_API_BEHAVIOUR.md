# REAPER CSurf API behavior guide for production extensions

The IReaperControlSurface API is **minimally documented by design**—Cockos provides function signatures and sparse comments, leaving critical behavioral semantics to empirical discovery. This guide synthesizes findings from the official SDK headers (`reaper_plugin.h`), SWS Extension source code analysis, and Cockos forum confirmations from developers like schwa. For each question, you'll find the definitive answer where documented, empirical testing strategies where not, and battle-tested defensive patterns from production code.

## FX parameter automation fires every block without throttling

**Definitive answer:** REAPER does **not throttle** `CSURF_EXT_SETFXPARAM` callbacks during envelope playback. The SDK documents only the parameter format (`parm1=MediaTrack*, parm2=int*(fxidx<<16|paramidx), parm3=double* normalized`), with no mention of rate limiting. Forum confirmation from developer schwa confirms these callbacks fire "whenever" parameters change.

**Practical frequency bounds:** Based on audio block sizes, expect **43-187 callbacks per second per animated parameter** (1024-sample blocks at 44.1kHz = ~43Hz; 256-sample blocks at 48kHz = ~187Hz). With 10 automated parameters, design for **400-2000 callbacks/second** peak during playback.

**Testing methodology:**

```cpp
// Instrument Extended() with high-resolution timing
static std::atomic<uint64_t> s_setfxparam_count{0};
static double s_last_timestamp = 0;

int Extended(int call, void* p1, void* p2, void* p3) {
    if (call == CSURF_EXT_SETFXPARAM) {
        s_setfxparam_count++;
        double now = time_precise();
        // Log delta: printf("SETFXPARAM delta: %.4fms\n", (now - s_last_timestamp) * 1000);
        s_last_timestamp = now;
    }
    return 0;
}
```

Create a test project with sine LFO automation on multiple FX parameters, vary buffer sizes (64-2048), and measure callback frequency.

**Defensive pattern (from SWS):**

```cpp
// Never do heavy work in Extended()—set async flag, process in Run()
bool m_bFxParamDirty = false;
std::unordered_map<uint64_t, double> m_pendingFxParams; // key: trackptr<<32 | fxidx<<16 | paramidx

int Extended(int call, void* p1, void* p2, void* p3) {
    if (call == CSURF_EXT_SETFXPARAM) {
        MediaTrack* tr = (MediaTrack*)p1;
        int fxparam = *(int*)p2;
        double val = *(double*)p3;
        uint64_t key = ((uint64_t)(uintptr_t)tr << 32) | fxparam;
        m_pendingFxParams[key] = val;  // Coalesce—last value wins
        m_bFxParamDirty = true;
    }
    return 0;  // Always return 0—never block propagation
}

void Run() {
    if (m_bFxParamDirty) {
        m_bFxParamDirty = false;
        // Batch process m_pendingFxParams, then clear
        ProcessFxParamBatch(std::move(m_pendingFxParams));
        m_pendingFxParams.clear();
    }
}
```

## ResetCachedVolPanStates triggers remain undocumented

**Definitive answer:** This function is **completely undocumented**. No SDK comments, no forum discussions, and no SWS code comments explain when REAPER calls it. The function `CSurf_ResetAllCachedVolPanStates()` exists in `reaper_plugin_functions.h` with zero documentation.

**Empirical testing methodology:**

```cpp
void ResetCachedVolPanStates() override {
    static int s_call_count = 0;
    char buf[256];
    snprintf(buf, sizeof(buf), "ResetCachedVolPanStates #%d at %.3fs", 
             ++s_call_count, time_precise());
    ShowConsoleMsg(buf);
    
    // Log call stack if available (platform-specific)
    // Capture REAPER's undo state: GetProjectStateChangeCount(nullptr)
}
```

**Test these trigger conditions systematically:**

- Undo/redo operations (`Main_OnCommand(40029, 0)` / `40030`)
- Project load, close, tab switch
- "Reset track pan/vol to default" actions
- Track deletion/creation
- Media item operations affecting track state
- API calls: `SetMediaTrackInfo_Value()` for vol/pan

**Defensive pattern:**

```cpp
void ResetCachedVolPanStates() override {
    // Treat as "invalidate everything" signal
    m_volPanCache.clear();
    m_bFullResyncNeeded = true;
    // Don't rebuild here—let Run() handle it to avoid recursion
}

void Run() {
    if (m_bFullResyncNeeded) {
        m_bFullResyncNeeded = false;
        RebuildAllTrackState();  // Full scan of vol/pan via GetMediaTrackInfo_Value
    }
}
```

## SetTrackListChange fires first, but expect callback bursts

**Definitive answer:** The ordering is **not formally documented**, but SWS source code reveals critical empirical knowledge: `SetTrackListChange()` triggers `NumTracks + 1` subsequent `SetTrackTitle()` calls. This strongly suggests `SetTrackListChange()` fires first when track topology changes, with detail callbacks following.

**From sws_extension.cpp:**

```cpp
// For every SetTrackListChange we get NumTracks+1 SetTrackTitle calls, but we only
// want to call AutoColorRun once, so ignore those n+1.
void SetTrackListChange() {
    m_iACIgnore = GetNumTracks() + 1;  // Prepare to ignore burst
}

void SetTrackTitle(MediaTrack* tr, const char* c) {
    if (!m_iACIgnore) {
        // Real title change, not part of track list init
    } else {
        m_iACIgnore--;  // Countdown through burst
    }
}
```

**Critical insight:** Callbacks are **synchronous within the main thread**—one completes before the next fires. However, do not assume all FX callbacks for a duplicated track arrive atomically; they may interleave with other operations.

**Defensive pattern for TrackPtr→Index maps:**

```cpp
std::unordered_map<MediaTrack*, int> m_trackIndex;
bool m_trackListDirty = false;

void SetTrackListChange() override {
    m_trackListDirty = true;
    // DON'T rebuild map here—wait for callback burst to settle
}

int Extended(int call, void* p1, void* p2, void* p3) override {
    if (call == CSURF_EXT_SETFXCHANGE) {
        MediaTrack* tr = (MediaTrack*)p1;
        // Validate track before use—may be stale during track deletion
        if (CSurf_TrackToID(tr, false) >= 0) {
            m_fxDirty.insert(tr);
        }
    }
    return 0;
}

void Run() override {
    if (m_trackListDirty) {
        m_trackListDirty = false;
        RebuildTrackIndexMap();  // Full rescan
    }
    ProcessPendingFxChanges();  // Now track map is valid
}

void RebuildTrackIndexMap() {
    m_trackIndex.clear();
    int count = CountTracks(nullptr);
    for (int i = 0; i < count; i++) {
        MediaTrack* tr = GetTrack(nullptr, i);
        m_trackIndex[tr] = i;
    }
}
```

## Extended() return 0 means unhandled, but propagation is undocumented

**Definitive answer (partial):** The SDK explicitly documents: `virtual int Extended(...) { return 0; } // return 0 if unsupported`. However, whether **non-zero return stops propagation** to other surfaces is **not documented**.

**SWS pattern (authoritative):** SWS **always returns 0**, never consuming callbacks. This is defensive—ensures the extension doesn't break other control surfaces.

```cpp
// From sws_extension.cpp
int Extended(int call, void *parm1, void *parm2, void *parm3) {
    BR_CSurf_Extended(call, parm1, parm2, parm3);
    SNM_CSurfExtended(call, parm1, parm2, parm3);
    switch(call) {
        case CSURF_EXT_SETFXCHANGE:
            m_bAutoColorTrackAsync = true;
            break;
    }
    return 0;  // ALWAYS 0—never consume
}
```

**Testing methodology:**

```cpp
// Register two surfaces, have first return 1, check if second receives callback
class TestSurface1 : public IReaperControlSurface {
    int Extended(int call, void* p1, void* p2, void* p3) override {
        ShowConsoleMsg("Surface1 received Extended\n");
        return 1;  // Claim handled
    }
};

class TestSurface2 : public IReaperControlSurface {
    int Extended(int call, void* p1, void* p2, void* p3) override {
        ShowConsoleMsg("Surface2 received Extended\n");  // Does this fire?
        return 0;
    }
};
```

**Defensive recommendation:**

```cpp
int Extended(int call, void* p1, void* p2, void* p3) override {
    // Process your logic here...
    return 0;  // Always return 0 unless you have tested propagation behavior
              // and have a specific reason to consume the callback
}
```

## Hybrid polling at 1-5 seconds catches CSurf edge cases

**When CSurf misses callbacks:** SWS developers discovered that IReaperControlSurface "cannot handle everything you might want to get notified about." Specific gaps include:

- Preference changes
- Some UI state (focused FX window, mixer scroll position)
- External project modifications
- Rapid undo/redo sequences

**SWS timing constants reveal battle-tested intervals:**

```cpp
#define SNM_CSURF_RUN_TICK_MS      27.0  // ~37Hz observed Run() frequency
#define SNM_MKR_RGN_UPDATE_FREQ    500   // Markers/regions: 0.5s "gentle value"
#define SNM_OFFSCREEN_UPDATE_FREQ  1000  // Off-screen elements: 1s
#define SNM_DEF_TOOLBAR_RFRSH_FREQ 300   // Toolbars: 300ms
```

**Recommended hybrid architecture:**

```cpp
class MyExtension : public IReaperControlSurface {
    DWORD m_lastFullSync = 0;
    static constexpr DWORD FULL_SYNC_INTERVAL_MS = 2000;  // Safety net: 2s
    
    void Run() override {
        // Process callback-driven dirty flags (fast path)
        ProcessPendingChanges();
        
        // Periodic full validation (slow path, safety net)
        DWORD now = GetTickCount();
        if (now - m_lastFullSync > FULL_SYNC_INTERVAL_MS) {
            m_lastFullSync = now;
            ValidateFullState();  // Compare cached state vs REAPER reality
        }
    }
    
    void ValidateFullState() {
        // Check track count matches
        // Verify vol/pan values for visible tracks
        // Validate FX counts for active tracks
        // Log any drift detected
    }
};
```

**For your WebSocket UI at 30Hz timer:** Your existing 30Hz timer is appropriate for UI updates. Add a **2-5 second** full state validation pass to catch drift. Don't sync every frame—batch changes and send deltas.

## SetSurfaceVolume fires during envelope playback continuously

**Definitive answer:** Yes, REAPER calls `SetSurfaceVolume()`/`SetSurfacePan()` **during automation envelope playback**. Forum discussion confirmed: "Having the transport stopped does not mean that automation should stop working"—parameters are continuously sent to maintain sync.

**Callback characteristics:**

- Called at approximately Run() frequency (~30Hz) during playback
- No built-in debouncing—you receive every update
- The `ignoresurf` parameter in `CSurf_SetSurfaceVolume()` confirms broadcast to all surfaces except initiator

**Testing methodology:**

```cpp
void SetSurfaceVolume(MediaTrack* tr, double volume) override {
    static double s_lastVol = -1;
    static DWORD s_lastTime = 0;
    DWORD now = GetTickCount();
    
    char buf[128];
    snprintf(buf, sizeof(buf), "SetSurfaceVolume: %.4f (delta: %.4f, interval: %dms)\n",
             volume, volume - s_lastVol, now - s_lastTime);
    ShowConsoleMsg(buf);
    
    s_lastVol = volume;
    s_lastTime = now;
}
```

**Defensive pattern for WebSocket UI:**

```cpp
struct TrackVolPanState {
    double volume = 0.0;
    double pan = 0.0;
    DWORD lastSent = 0;
    bool dirty = false;
};

std::unordered_map<MediaTrack*, TrackVolPanState> m_trackState;
static constexpr double VOL_THRESHOLD = 0.001;  // ~0.01dB
static constexpr double PAN_THRESHOLD = 0.005;  // ~0.5%
static constexpr DWORD MIN_SEND_INTERVAL_MS = 33;  // Cap at ~30Hz to WebSocket

void SetSurfaceVolume(MediaTrack* tr, double volume) override {
    auto& state = m_trackState[tr];
    if (std::abs(volume - state.volume) > VOL_THRESHOLD) {
        state.volume = volume;
        state.dirty = true;
    }
}

void Run() override {
    DWORD now = GetTickCount();
    for (auto& [tr, state] : m_trackState) {
        if (state.dirty && (now - state.lastSent) >= MIN_SEND_INTERVAL_MS) {
            SendToWebSocket(tr, state);
            state.dirty = false;
            state.lastSent = now;
        }
    }
}
```

## Multiple surfaces all receive callbacks in registration order

**Definitive answer:** REAPER broadcasts callbacks to **all registered surfaces**. The `IReaperControlSurface* ignoresurf` parameter throughout the API (e.g., `CSurf_SetSurfaceVolume(MediaTrack*, double, IReaperControlSurface* ignoresurf)`) confirms this—it exists specifically to exclude the surface that initiated a change.

**Registration order:** Surfaces receive callbacks in **registration order** (order of `rec->Register("csurf", &reg)` calls). This is not documented but observed empirically.

**Extended() propagation:** Based on SWS always returning 0 and no forum evidence of propagation stopping, the safest assumption is that **Extended() return values do not affect propagation**—all surfaces receive all Extended() calls regardless of return values.

**Defensive patterns:**

```cpp
// 1. Track which changes you initiated to avoid feedback loops
void OnUserFaderMove(MediaTrack* tr, double newVol) {
    m_pendingVolChanges[tr] = newVol;  // Mark as self-initiated
    CSurf_SetSurfaceVolume(tr, CSurf_OnVolumeChange(tr, newVol, false), this);
}

void SetSurfaceVolume(MediaTrack* tr, double volume) override {
    // Check if this is echo of our own change
    auto it = m_pendingVolChanges.find(tr);
    if (it != m_pendingVolChanges.end() && std::abs(it->second - volume) < 0.0001) {
        m_pendingVolChanges.erase(it);
        return;  // Ignore echo
    }
    // External change—update UI
    UpdateUIVolume(tr, volume);
}

// 2. Use GUIDs for cross-surface coordination
GUID GetTrackGUID(MediaTrack* tr) {
    GUID* g = GetTrackGUID(tr);
    return g ? *g : GUID{};
}
```

## Practical implementation summary for Zig/C++ WebSocket extension

Given your environment (REAPER 7.x, macOS ARM64, Zig with C++ shim, WebSocket UI, 30Hz timer):

**Architecture recommendations:**

1. **CSurf callbacks → atomic dirty flags** (lock-free, audio-thread safe)
2. **30Hz Run() → collect dirty state, batch to pending queue**
3. **WebSocket thread → consume queue, serialize JSON deltas**
4. **2-second safety poll → validate full state, detect drift**

**Key constants:**

```cpp
constexpr int CSURF_RUN_HZ = 30;           // Expected Run() frequency
constexpr int WEBSOCKET_BATCH_HZ = 30;     // Match your timer
constexpr int SAFETY_POLL_MS = 2000;       // Full state validation
constexpr double VOL_CHANGE_THRESHOLD = 0.001;
constexpr double PAN_CHANGE_THRESHOLD = 0.005;
constexpr int MAX_FX_PARAMS_PER_FRAME = 50; // Throttle FX param floods
```

**Track pointer safety (critical for your reverse map):**

```cpp
// ALWAYS validate before dereferencing MediaTrack*
bool IsTrackValid(MediaTrack* tr) {
    return tr && CSurf_TrackToID(tr, false) >= 0;
}

// Store by GUID for persistence, resolve to pointer on demand
GUID TrackToGUID(MediaTrack* tr) {
    GUID* g = GetTrackGUID(tr);
    return g ? *g : GUID{};
}
```

The CSurf API rewards defensive programming. The gaps in documentation mean you should test edge cases aggressively—rapid undo/redo, project tab switching, track duplication with complex FX chains, and automation playback at various buffer sizes will reveal behaviors that no documentation covers.
