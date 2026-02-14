# REAPER recording items cannot be accessed via plugin API during recording

**REAPER intentionally keeps recording items internal until recording stops.** There is no documented or undocumented API—in C++, Lua, EEL, or Python—to access in-progress recording items, recording sinks, or the live waveform data shown in the arrange view. This limitation is confirmed across REAPER forums, the SWS extension source code, and the complete CSURF_EXT callback documentation. The recommended approach is to synthesize "virtual" recording items by tracking recording start time and polling playback position at ~30Hz.

## The core limitation is architectural, not an API oversight

Standard item APIs (`CountTrackMediaItems`, `GetTrackMediaItem`) only return committed items after recording stops. Justin Frankel has confirmed this behavior in forum responses—recording items exist only as internal REAPER structures during recording. The `PCM_sink` class that REAPER uses internally for recording output has methods like `GetLastSecondPeaks()` and `GetPeakInfo()`, but **no API exposes the active recording sink** for any track.

The SWS extension—the most comprehensive REAPER extension with over 900 actions—does not solve this problem. Its control surface implementation (`SWSTimeSlice` class) uses the same `SetPlayState(bool play, bool pause, bool rec)` callback and only accesses items after recording stops. Features like "Auto-Group Recorded Items" explicitly wait for recording to complete.

## Complete CSURF_EXT callback reference for recording

The `IReaperControlSurface::Extended()` method receives these recording-relevant callbacks:

| Callback | Value | Parameters |
|----------|-------|------------|
| `CSURF_EXT_SETINPUTMONITOR` | 0x00010001 | parm1=(MediaTrack*), parm2=(int*)recmonitor |
| `CSURF_EXT_SETAUTORECARM` | 0x00010003 | parm1=0 disable, !0 enable |
| `CSURF_EXT_SETRECMODE` | 0x00010004 | parm1=(int*) 0=autosplit, 1=tape mode |
| `CSURF_EXT_RESET` | 0x0001FFFF | Full surface state reset |

**No CSURF_EXT callback exists for recording item creation, recording position updates, or recording waveform data.** The `SetPlayState(bool play, bool pause, bool rec)` method fires only at state transitions, not continuously during recording. MCU and OSC implementations also lack recording item visualization—they only handle transport LED states and track arm indicators.

## Synthesizing virtual recording items: the working approach

Since the API cannot provide recording items, you must calculate them yourself by capturing start time and polling position:

**Recording start detection** requires storing position when `SetPlayState(true, false, true)` fires:

```cpp
void SetPlayState(bool play, bool pause, bool rec) {
    if (rec && !m_wasRecording) {
        // Recording just started
        m_recordStartPos = GetPlayPosition2();
        CacheRecordArmedTracks();  // Store which tracks are armed
    }
    m_wasRecording = rec;
}
```

**Position polling** happens in `Run()` at ~30Hz:

```cpp
void Run() {
    if (GetPlayState() & 4) {  // Recording active
        double currentPos = GetPlayPosition2();
        double recordingLength = currentPos - m_recordStartPos;
        // Send position/length to tablet via WebSocket
    }
}
```

**Per-track recording state** uses these track info values:

| Parameter | Purpose |
|-----------|---------|
| `I_RECARM` | 1 if track is record-armed |
| `I_RECINPUT` | Input source (0..n=mono, 512+n=rearoute, 1024=stereo, 4096=MIDI) |
| `I_RECMODE` | Recording mode (0=input, 1=output, 2=none, etc.) |
| `I_RECMON` | Monitor mode (0=off, 1=normal, 2=not when playing) |
| `B_RECMON_IN_EFFECT` | **Read-only** current audio-thread monitoring state |

## Handling punch-in, pre-roll, and loop recording edge cases

**Punch-in recording** starts at the time selection, not the cursor position. Query this with:

```cpp
double punchStart, punchEnd;
GetSet_LoopTimeRange2(nullptr, false, false, &punchStart, &punchEnd, false);
// If time selection exists and auto-punch is enabled, recording starts at punchStart
```

The time selection (with `isLoop=false`) controls punch points, while loop points (with `isLoop=true`) control repeat behavior. When both exist, recording may start at `punchStart` rather than `GetPlayPosition2()` at the moment `SetPlayState` fires.

**Pre-roll and count-in** have no direct API. The workaround is detecting when actual recording begins by comparing positions:

- Store `GetCursorPosition()` when user initiates recording
- In `Run()`, check if `GetPlayPosition2()` is advancing past cursor position
- Count-in causes a delay before position advances; pre-roll causes position to be before cursor

**Loop recording** creates multiple takes sequentially. Each loop iteration adds a take to the same item (in take mode) or creates new items (in split mode). You can detect loop crossings by monitoring when `GetPlayPosition2()` jumps backward. The `AdvancePlaybackPosition()` function returns flags including bit 1 for "looped selection" and bit 2 for "looped project."

**Cancel vs stop behavior**: Both call `SetPlayState(false, false, false)`, but canceling (Escape) may discard recording without creating items. Monitor `SetTrackListChange()` after recording stops—it fires when new items are created. If it doesn't fire, recording was likely canceled.

## Alternative approaches that don't fully solve the problem

**Audio_RegHardwareHook** provides audio thread callbacks before/after REAPER's processing, but this is C++ only (not available to ReaScript) and gives you raw audio buffers, not item metadata. You could theoretically compute peaks from this, but you still don't get position/length information relative to the timeline.

**CreateTrackAudioAccessor** creates accessor objects for tracks, but documentation indicates main-thread-only access and it's designed for playback sources, not active recording sinks.

**Hooking into arrange view drawing** is not possible—REAPER doesn't expose its drawing pipeline to extensions.

## Implementation recommendations for your tablet timeline

For your control surface extension displaying recording on an iPad via WebSocket:

1. **Cache armed tracks** when `SetPlayState(rec=true)` fires by iterating all tracks and storing those with `I_RECARM=1`
2. **Store recording start time** as `GetPlayPosition2()` at recording start, adjusted for punch-in if time selection exists
3. **Poll in Run()** every ~33ms (30Hz matches REAPER's control surface tick rate) and calculate length as `currentPos - startPos`
4. **Send delta updates** to the tablet with track GUID, start position, and current length
5. **Handle SetTrackListChange()** after recording stops to get actual committed items with final positions

For punch-in/punch-out precision, also query `GetSet_LoopTimeRange2()` and check if the recording mode uses time selection punch (Action 40076 toggles this). The recording start position should be `max(cursorPos, punchStart)` when punch is enabled.

Consider posting a feature request on forum.cockos.com for `GetTrackRecordingItem()` or a `CSURF_EXT_RECORDINGPROGRESS` callback—Justin Frankel is responsive to well-articulated API requests, and this is a genuine gap in the control surface API.
