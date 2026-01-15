# CSurf Hybrid Architecture

**Status:** Future optimization - significant refactor for ~50% CPU reduction

## Overview

REAPER's CSurf (Control Surface) interface provides **push notifications** for most track-level state changes, eliminating redundant polling.

## CSurf Callbacks Available

| CSurf Callback | Replaces Polling For |
|----------------|---------------------|
| `SetPlayState(play, pause, rec)` | Transport state |
| `SetSurfaceVolume(track, vol)` | Track volume |
| `SetSurfacePan(track, pan)` | Track pan |
| `SetSurfaceMute(track, mute)` | Track mute |
| `SetSurfaceSolo(track, solo)` | Track solo |
| `SetTrackListChange()` | Track add/remove/reorder |
| `Extended(CSURF_EXT_SETPROJECTMARKERCHANGE)` | Marker/region changes |
| `Extended(CSURF_EXT_SETBPMANDPLAYRATE)` | Tempo/BPM changes |
| `Extended(CSURF_EXT_SETFXENABLED)` | FX bypass state |

## CSurf Gaps (Still Require Polling)

- Media item changes (add/delete/move/resize)
- Cursor position
- Time selection
- Envelope edits
- Meter values (always polled)
- Zoom/scroll

## The SWS Pattern

Callbacks set dirty flags; `Run()` processes in batches:

```cpp
// Callback (called by REAPER when state changes)
void SetSurfaceVolume(MediaTrack* track, double volume) {
    m_tracksDirty = true;  // Flag for Run() to process
}

// Run() called at 30Hz
void Run() {
    if (m_tracksDirty) {
        m_tracksDirty = false;
        BroadcastTrackState();
    }
    // Poll for state CSurf doesn't notify...
    PollItems();
    PollCursor();
}
```

## Implementation Requirements

1. Implement `IReaperControlSurface` interface in Zig (or C wrapper)
2. Register via `plugin_register("csurf_inst", &surface)`
3. Convert polling to dirty-flag pattern
4. Maintain polling for CSurf gaps

## Why This Is Low Priority

The current 30Hz polling is within REAPER's designed parameters. CSurf hybrid is a significant refactor for gains that may not be perceptible to users. Worth considering if profiling shows actual CPU concerns.

## References

- REAPER SDK: `reaper_csurf.h`
- SWS source: `Breeder/BR_ContinuousActions.cpp` (example CSurf implementation)
- Our current polling: `main.zig` timer callback
