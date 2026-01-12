# Pending Items

Consolidated from backend audits and completed plans. Items not yet addressed.

**Created:** 2026-01-07

---

## Frontend

### FX Modal for TrackInfoBar

~~Add long-press (500ms) on FX button to open FX modal.~~

**FX Modal features (with current APIs):**
- ~~List FX chain with preset names~~
- ~~Preset navigation (prev/next) via `fx/presetNext`, `fx/presetPrev`~~
- ~~Show modified indicator~~
- ~~Track-level FX bypass toggle~~

**Status:** Implemented (2026-01-11)

---

### Subscription Buffer Setting

Add user-configurable subscription buffer for viewport-driven track loading. Currently hardcoded at 30 tracks beyond visible viewport. Users on slow WiFi could reduce this to minimize bandwidth; users scrolling fast through huge sessions could increase for fewer placeholders.

**Location:** Settings menu → Performance section
**Default:** 30 (current)
**Range:** TBD (tested 10 and 30, both work well)

**Status:** Not implemented

---

### Dedicated Mixer View

A placeholder exists at `frontend/src/views/mixer/` for a full-screen mixer with larger faders. Currently the mixer is embedded in Studio view. The dedicated view would provide:

- Full-screen fader strips optimized for touch
- Larger meters and controls
- Minimal chrome for maximum channel visibility

**Status:** Placeholder only, not implemented

---

### ~~Double-Tap Time Display → Quick Actions Panel~~

~~Double-tap on the time/position display in PersistentTransport opens a slide-up panel with commonly needed project actions.~~

**Features implemented:**
- ~~Project name display with dirty indicator~~
- ~~Save, Undo, Redo buttons~~
- ~~Metronome and Repeat toggles~~
- ~~Tempo display/edit with +/- buttons and Tap Tempo~~
- ~~New reusable BottomSheet component for slide-up panels~~

**Status:** Implemented (2026-01-12)

---

### Long-Press Position Display → Marker Navigation

Long-press (500ms) on the time/position display should show a popup with all project markers for quick navigation. This is a proven UX pattern from Logic Remote.

**Interaction:**
- Touch-hold on position display (bar.beat or time readout)
- After 500ms, show dropdown/popover with marker list
- Tap any marker → seek to that position
- Include regions (start points) optionally

**Visual feedback:**
- At 200ms: subtle pulse animation on display
- At 500ms: popup appears with 200ms fade-in

**Implementation notes:**
- Reuse existing marker data from store
- Consider including region start/end points
- Sort by position, show name + time

**Note:** Could be superseded by or coexist with the Double-Tap Quick Actions Panel above. Double-tap gives quick actions + navigation; long-press could remain as a faster path to marker-only list.

**Status:** Not implemented

---

## Backend

### ~~`track/setColor` Command~~

~~Add command to set track color. Currently tracks event includes `color` field (read) but no write command exists.~~

**Status:** Implemented (2026-01-12)

---

### ~~`trackFx/setEnabled` Command (Per-FX Bypass)~~

~~Add command to enable/disable individual FX in a track's FX chain.~~

**Status:** Implemented (2026-01-12) — Command is `trackFx/setEnabled` (not `fx/setEnabled`) to distinguish from future item FX support. Per-FX enabled state included in `track/getFx` response.

---

### Move Static Buffers to test_utils

**Priority:** Low

Test-only static buffer patterns remain in production modules:

| File | Function | Purpose |
|------|----------|---------|
| `items.zig` | `pollStatic` | Test convenience wrapper |
| `markers.zig` | `pollStatic` | Test convenience wrapper |
| `tracks.zig` | test helpers | Static buffers for mock tracks |

These don't affect production but would be cleaner in a dedicated `test_utils.zig`.

---

## Error Handling (Deferred)

### Event Serialization `toJson` Methods

**Priority:** Low (acceptable for now)

~150 instances of `catch return null` in `toJson` methods across state modules. These are **acceptable** because:

1. Production code now uses `toJsonAlloc` with scratch arena (no buffer limits)
2. Fixed-buffer `toJson` methods are only used in tests
3. Event serialization failures are non-critical (client just misses one update)

If ever revisited, the pattern would be to refactor each `toJson` into:
- `writeJson(writer: anytype) !void` — internal, uses `try`
- `toJson(buf: []u8) ?[]const u8` — wrapper that catches and logs

The full catalog was in `error_handling.md` (deleted during 2026-01-07 cleanup).

---

## Future Considerations

These are deferred features mentioned in research but not on the immediate roadmap:

### Viewport-Driven Items/Markers

Tracks use index-based viewport subscriptions. Items and markers will use time-range subscriptions:

```typescript
{ "type": "item/subscribe", "timeRange": { "start": 0.0, "end": 120.0 } }
```

This aligns with how arrange view scrolling works (horizontal = time, not track index).

**Entity Roadmap:**
| Entity | Viewport Type | Status |
|--------|---------------|--------|
| Tracks | Track indices | Done |
| Items | Time range | Future |
| Markers/Regions | Time range | Future |
| FX/Sends | Expanded track state | Future |

**Status:** Architecture designed, not implemented

### Per-Client Track Filtering on Broadcast

**Priority:** Low (optimization)

Currently, track subscriptions optimize **polling** but not **broadcasting**:

- Each client can subscribe to different track ranges (e.g., Client A: 0-10, Client B: 50-60)
- Backend polls only the union of all subscriptions (tracks 0-10 and 50-60)
- **However**, `shared_state.broadcast()` sends the same JSON to ALL clients
- Both clients receive all 22 tracks instead of just their subscribed range

**Impact:** Wastes bandwidth when multiple clients view different portions of large projects. For single-client usage or overlapping viewports, impact is negligible.

**Implementation options:**
1. **Per-client serialization** — Serialize tracks per-client based on their subscription. More CPU, but straightforward.
2. **Chunked broadcast** — Split track data by index ranges, send relevant chunks per-client.
3. **Client-side filtering** — Keep current broadcast, let frontend ignore tracks outside its viewport (already happens implicitly).

**Status:** Not implemented. Current design is acceptable for typical usage (1-2 clients, overlapping viewports).

### Mobile Safari Performance

Gotchas discovered during research:

- **Momentum scroll** — iOS doesn't fire scroll events during inertial scrolling; need `requestAnimationFrame` polling
- **Memory limit** — 2-4GB regardless of device RAM; prune data outside 2× viewport aggressively
- **Viewport pruning** — More aggressive garbage collection needed on iOS than desktop

**Status:** Noted for future mobile optimization pass

### WebSocket Compression for Action List

The `action/getActions` command returns ~985KB of JSON (15,619 actions across 6 sections). Fine for local WiFi (<1 second) but could benefit from compression.

**Blocker:** websocket.zig library has per-message deflate disabled for Zig 0.15. Library author noted: "Compression is disabled as part of the 0.15 upgrade. I do hope to re-enable it soon."

**When library supports it:**
```zig
.compression = .{
    .write_threshold = 256,  // Only compress messages > 256 bytes
    .retain_write_buffer = true,
},
```

**Expected:** ~985KB → ~60-80KB compressed.

**Workaround if needed:** Link system zlib via `@cImport`, compress at application layer, send binary frames with gzip magic bytes (`0x1f 0x8b`).

**Status:** Blocked on upstream library

### CSurf Hybrid Architecture

Phase 3 of the optimization plan suggested investigating CSurf (Control Surface) integration for:
- Native REAPER control surface protocol
- Reduced WebSocket overhead for high-frequency updates
- Hardware controller support

**Status:** Research only, low priority

### ReaPack Integration

Distribute the extension via ReaPack for easier installation:
- Auto-updates
- Dependency management
- Cross-platform packaging

**Status:** Post v1.0 consideration

### SWS Region Playlist Import

Import existing SWS auto-generated region playlists for compatibility with users migrating from SWS workflow.

**Status:** Deferred from Cue List backend plan

### Toggle State Change Events: Named IDs vs Numeric IDs

**Context:** Toggle state subscriptions now accept both numeric `commandIds` (native REAPER actions) and `names` (SWS/scripts like `_SWS_AWMRECTOG`). However, change events always use numeric IDs, requiring frontend to reverse-translate.

**Current flow:**
```
Subscribe: { names: ["_SWS_AWMRECTOG"] }
Response: { states: {"_SWS_AWMRECTOG": 1}, nameToId: {"_SWS_AWMRECTOG": 53532} }
Change event: { changes: {"53532": 0} }  ← numeric ID
Frontend: reverse-lookup 53532 → "_SWS_AWMRECTOG"
```

**Why it's safe:** Numeric IDs are stable within a REAPER session. The `nameToId` mapping captured at subscription time remains valid until WebSocket disconnect. On REAPER restart, the socket drops, client reconnects, re-subscribes, and gets fresh mapping.

**Why consider changing:** The current design pushes translation complexity to the frontend. This caused a subtle bug where change events weren't updating the UI because numeric IDs weren't being translated back to named keys. Sending named IDs directly in change events would:
- Eliminate frontend reverse-lookup logic
- Prevent translation bugs
- Keep backend as single source of truth for ID resolution

**Implementation if pursued:**
- Backend maintains `id_to_name` reverse mapping per client (built at subscription time)
- Change event serialization checks reverse map, uses name if found, numeric ID otherwise
- Mixed format in single event: `{"40364": 0, "_SWS_AWMRECTOG": 1}`

**Status:** Working as-is; consider refactoring if toggle subscription logic is revisited

---

## Completed (Reference)

The following major items were completed during the 2026-01-07 cleanup:

- Duplicate command registry removal (~320 lines)
- Unicode UTF-8 encoding fix
- MAX_* constants consolidation
- Global state → CommandContext refactor
- Silent error handling audit (HIGH/MEDIUM items)
- JSON buffer migration to scratch arena
- DEBUG_LOGGING disabled for release
- Mock deleteItem implementation
- REAPER API quirks documented in API.md
- **SPSC queue research** — concluded mutex is optimal for 30Hz polling; lock-free only needed for audio thread integration which we don't use

**2026-01-10:**
- **Momentum scrolling for timeline pan** — velocity-based inertia with 0.965 friction, respects prefers-reduced-motion

**2026-01-11:**
- **Global select-none** — centralized text selection control at App root; removed redundant select-none from 21 components; CSS exception for input/textarea elements
