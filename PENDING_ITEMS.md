# Pending Items

Consolidated from backend audits and completed plans. Items not yet addressed.

**Created:** 2026-01-07

---

## Frontend

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

## Backend

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
