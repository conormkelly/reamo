# SWS REAPER region playlist implementation for Zig extension development

The SWS Region Playlist is implemented primarily in `SnM/SnM_RegionPlaylist.cpp` and relies on REAPER's loop mechanism rather than a true scheduling API. Understanding its design decisions—and limitations—will help you build a more robust implementation while maintaining compatibility where sensible.

## Region ID handling uses displayed numbers, not stable GUIDs

SWS playlists reference regions by **markrgnindexnumber** (the displayed ID in REAPER's UI), not by GUID or any other stable identifier. This creates significant brittleness: when users run "Reorder all markers/regions" or manually renumber regions, playlist entries become misaligned with their intended targets. The SWS team documented this as a known limitation stemming from the feature being "kind of a hack" per GitHub issue #1512.

**When a referenced region is deleted**, SWS displays **"Unknown region"** in the playlist UI. Validation occurs lazily during display and playback—not on playlist load. This behavior appears in both the codebase and GitHub issue #466, which addressed an early bug where region addition could produce spurious "Unknown region" entries.

**For your Zig implementation**, consider using REAPER's stable GUID API instead:

```c
// Get GUID for region at enumeration index X
GetSetProjectInfo_String(proj, "MARKER_GUID:X", buf, bufSz, false);

// Reverse lookup: get enumeration index from GUID  
GetSetProjectInfo_String(proj, "MARKER_INDEX_FROM_GUID:{guid}", buf, bufSz, false);
```

This approach survives renumbering operations. Store GUIDs in your playlist format, then resolve to current positions at playback time using `EnumProjectMarkers3` to iterate and `MARKER_INDEX_FROM_GUID` to locate specific regions.

## Transport interaction piggybacks on REAPER's loop mechanism

SWS Region Playlist does not have independent play/pause controls—it **manipulates REAPER's time selection and loop points** to control which region plays. When a user hits Stop on REAPER's transport, playlist playback stops but the playlist's internal state (current region, next scheduled region) persists. However, you cannot pause and resume from the same position; restarting plays from the beginning of the current region.

Pressing Play on REAPER's transport (not via SWS playlist UI) does **not** activate playlist mode—the playlist only engages when triggered through its specific actions like `S&M_PLAY_RGN_PLAYLIST`. The playlist maintains its own state tracking (`current region`, `next region`) separate from but coordinated with REAPER's transport.

**Critical limitation**: The loop-based mechanism fails when markers exist inside regions (issue #1512). Regions that end at exactly the same time as the next region begins can be skipped (issue #886—workaround: shorten regions by a few milliseconds).

## Seeking uses SetEditCurPos2 with hard jumps by default

SWS uses `SetEditCurPos2` for positioning:

```c
SetEditCurPos2(NULL, targetTime, true, false);
// Parameters: project (NULL=active), time in seconds, moveview, seekplay
```

The **moveview** parameter is `true` (scrolls arrange view), while **seekplay** behavior depends on context. For immediate seeking during playback, SWS typically calls transport functions in sequence rather than relying solely on seekplay.

**There is no crossfade or smoothing** on region transitions by default. The "smooth seek" feature (`S&M_PLAYLIST_OPT_SMOOTHSEEK_ON`) does not add audio crossfading—it simply delays the seek until the current region finishes playing, respecting REAPER's "play to end of current region" seeking preference.

For smooth seek to function correctly:
1. Enable REAPER preference: Audio → Seeking → "Do not change playback position immediately"
2. Enable SWS option: `S&M_PLAYLIST_OPT_TGL_SMOOTHSEEK`

**Recommended seeking pattern for your implementation**:

```c
// For immediate hard seek during playback
SetEditCurPos2(NULL, regionStartTime, false, true);  // seekplay=true

// For smooth seek, queue the target and let REAPER's seeking prefs handle timing
SetEditCurPos2(NULL, regionStartTime, false, false); // moveview=false, seekplay=false
// Then trigger play if needed
```

## EXTSTATE API provides two distinct persistence mechanisms

**Global ExtState** (survives REAPER restarts, shared across projects):

```c
void SetExtState(const char* section, const char* key, const char* value, bool persist);
const char* GetExtState(const char* section, const char* key);
bool HasExtState(const char* section, const char* key);
void DeleteExtState(const char* section, const char* key, bool persist);
```

With `persist=true`, values are stored in `reaper-extstate.ini` in REAPER's resources folder. Section and key parameters are **case-insensitive**.

**Project-scoped ExtState** (saved with RPP file):

```c
int SetProjExtState(ReaProject* proj, const char* extname, const char* key, const char* value);
int GetProjExtState(ReaProject* proj, const char* extname, const char* key, char* buf, int buf_sz);
bool EnumProjExtState(ReaProject* proj, const char* extname, int idx, char* key, int keysz, char* val, int valsz);
```

Pass `NULL` for `proj` to use the active project. Data persists in the RPP file and restores on project load.

**Critical limitation**: ExtState values are restricted to **single-line strings**. Newlines cause truncation when `persist=true`, and trailing spaces may be stripped. For complex data:

```c
// Serialize with a safe delimiter (pipe, semicolon, or JSON without newlines)
SetProjExtState(NULL, "MyExtension", "playlist1", "guid1|3|guid2|1|guid3|2");
// Format: regionGUID|loopCount|regionGUID|loopCount|...
```

**Size limits**: ProjExtState via web interface caps at ~16KB. Standard ExtState has no hard limit documented, but practical testing suggests **JSON blobs up to several hundred KB** work reliably.

**SWS storage approach**: SWS uses `SetProjExtState` for playlist data within the RPP file, and INI settings (S&M.ini) for user preferences like smooth seek toggles and UI font names. The `[RegionPlaylist]` section in S&M.ini stores global preferences.

## Multi-client concurrent editing defaults to last-write-wins

REAPER provides **no built-in locking mechanism** for extensions. The OSC and MIDI control surface implementations demonstrate this clearly: each controller maintains independent state (track bank position, selected track, current FX), and when multiple devices modify the same parameter, the last write wins without conflict detection.

**Patterns from existing implementations**:

- **Independent state per client**: Each OSC device tracks its own "current track" separately from other controllers and the REAPER UI
- **Feedback propagation**: REAPER sends feedback when internal changes occur, but not when changes originate from controllers—other controllers may become stale
- **No mutex support**: Extensions must implement their own coordination if needed

**For your WebSocket API**, consider these approaches:

1. **Last-write-wins (simplest)**: Accept concurrent edits, broadcast changes to all clients, let UI handle conflicts visually
2. **Optimistic locking via ExtState**:
   ```c
   // Check lock before editing
   if (strlen(GetExtState("MyExt", "playlist_lock")) == 0) {
       SetExtState("MyExt", "playlist_lock", "client_id", false);
       // ... perform edit ...
       SetExtState("MyExt", "playlist_lock", "", false);
   }
   ```
3. **Version numbers**: Include a version counter in your playlist state, reject edits with stale versions

**Practical recommendation**: Start with last-write-wins and broadcast all changes. Implement locking only if real-world usage reveals destructive conflicts. Most control surface use cases (live performance, studio mixing) involve a single operator at any moment.

## Recommended implementation architecture

Based on the research, here's a suggested design for your Zig extension:

| Component | Approach |
|-----------|----------|
| **Region references** | Store GUIDs (via `MARKER_GUID:X`), resolve at playback time |
| **Playlist persistence** | Use `SetProjExtState` with pipe-delimited or compact JSON (no newlines) |
| **Seeking** | `SetEditCurPos2(NULL, time, false, true)` for immediate seeks |
| **Transport monitoring** | Poll `GetPlayState()` and `GetPlayPosition()` in your Run() loop |
| **Boundary detection** | Compare `GetPlayPosition()` against current region end time |
| **Client synchronization** | Broadcast state changes via WebSocket, last-write-wins |
| **Settings persistence** | Global prefs in ExtState with `persist=true`, per-project in ProjExtState |

**Key source files to examine** in the SWS repository (clone from https://github.com/reaper-oss/sws):
- `SnM/SnM_RegionPlaylist.cpp` — Main playlist implementation
- `SnM/SnM_RegionPlaylist.h` — Data structures and class definitions
- `SnM/SnM.cpp` — Action registration including `PlaylistSeekPrevNext`, `PlaylistPlay`

## Testing and verification recommendations

For behaviors not fully documented, empirical testing will provide definitive answers:

1. **Region renumbering**: Create a playlist, run Actions → Markers → "Renumber all markers and regions", observe playlist state
2. **Transport interaction**: Start playlist playback, press Stop via transport (not playlist UI), observe if playlist resets or preserves position
3. **EXTSTATE limits**: Write progressively larger strings to `SetProjExtState`, verify retrieval up to your expected maximum playlist size
4. **Seeking accuracy**: Log `GetPlayPosition()` immediately after `SetEditCurPos2` with `seekplay=true` to measure actual seek latency

The SWS implementation's limitations—particularly around region ID stability and transport integration—represent opportunities for your Zig implementation to improve on the prior art while maintaining behavioral compatibility where it matters for existing users.
