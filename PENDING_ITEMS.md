# Pending Items

Consolidated from backend audits and completed plans. Items not yet addressed.

**Created:** 2026-01-07

---

## Frontend

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
