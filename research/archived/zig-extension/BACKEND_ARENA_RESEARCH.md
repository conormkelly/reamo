# Arena Allocation Strategy for Reamo

**Context:** Research notes on switching from fixed-size arrays to arena-based allocation for dynamic limits. Given REAPER's mantra is "audio production without limits", our control surface should follow suit.

---

## Initial Question

> What about arenas, do they help us out? A big ol arena?

Currently we have fixed limits for tracks, items, markers, etc. If we wanted to support N items, N tracks, we'd obviously need to switch to heap allocation. Do arenas fit this use case?

---

## Analysis: Arenas Are a Fantastic Fit

Arenas are actually a *fantastic* fit for our polling architecture. Here's why.

### The Insight: Our State Has Frame-Based Lifetimes

Every 33ms we:

1. Poll REAPER → build complete state snapshot
2. Diff against previous frame
3. Serialize to JSON, broadcast
4. Previous frame's data is now garbage

This is *exactly* what arenas are designed for — bulk allocate, use, reset. No individual frees, no fragmentation, no bookkeeping.

### Per-Frame Arena Pattern

```zig
const FrameArena = struct {
    buffer: []u8,
    fba: std.heap.FixedBufferAllocator,
    
    pub fn init(backing: Allocator, size: usize) !FrameArena {
        const buffer = try backing.alloc(u8, size);
        return .{
            .buffer = buffer,
            .fba = std.heap.FixedBufferAllocator.init(buffer),
        };
    }
    
    pub fn allocator(self: *FrameArena) Allocator {
        return self.fba.allocator();
    }
    
    pub fn reset(self: *FrameArena) void {
        self.fba.reset();
    }
    
    pub fn deinit(self: *FrameArena, backing: Allocator) void {
        backing.free(self.buffer);
    }
};
```

### Double-Buffered Arenas for Diffing

Since we need *two* frames of state (current and previous) for change detection:

```zig
const DoubleBufferedState = struct {
    arenas: [2]FrameArena,
    states: [2]*State,
    current: u1 = 0,
    
    pub fn init(backing: Allocator, arena_size: usize) !DoubleBufferedState {
        var self: DoubleBufferedState = .{
            .arenas = undefined,
            .states = undefined,
        };
        
        // Initialize both arenas
        self.arenas[0] = try FrameArena.init(backing, arena_size);
        errdefer self.arenas[0].deinit(backing);
        self.arenas[1] = try FrameArena.init(backing, arena_size);
        
        // Allocate initial state structs
        self.states[0] = try self.arenas[0].allocator().create(State);
        self.states[1] = try self.arenas[1].allocator().create(State);
        
        return self;
    }
    
    pub fn currentState(self: *DoubleBufferedState) *State {
        return self.states[self.current];
    }
    
    pub fn previousState(self: *DoubleBufferedState) *const State {
        return self.states[1 - self.current];
    }
    
    pub fn currentAllocator(self: *DoubleBufferedState) Allocator {
        return self.arenas[self.current].allocator();
    }
    
    // Called at START of each frame
    pub fn beginFrame(self: *DoubleBufferedState) !void {
        // Swap to other buffer
        self.current = 1 - self.current;
        
        // Reset the arena we're about to use (frees all previous-previous frame data)
        self.arenas[self.current].reset();
        
        // Allocate fresh state struct
        self.states[self.current] = try self.arenas[self.current].allocator().create(State);
        self.states[self.current].* = State.empty();
    }
};
```

### Timer Callback Becomes Beautifully Simple

```zig
var g_state: DoubleBufferedState = undefined;

fn timerCallback() void {
    // Begin new frame — resets arena, swaps buffers
    g_state.beginFrame() catch |err| {
        std.log.err("Frame allocation failed: {}", .{err});
        return;
    };
    
    const alloc = g_state.currentAllocator();
    const state = g_state.currentState();
    const prev = g_state.previousState();
    
    // Poll into current state — all allocations go to arena
    state.tracks = pollTracks(alloc, api) catch return;
    state.items = pollItems(alloc, api) catch return;
    state.markers = pollMarkers(alloc, api) catch return;
    
    // Diff against previous frame
    if (!state.tracks.eql(prev.tracks)) {
        const json = state.tracks.toJson(alloc) catch return;
        broadcast(json);
    }
    
    // End of callback — nothing to free!
    // Next frame's beginFrame() will reset this arena
}
```

### What This Buys Us

| Benefit | Explanation |
|---------|-------------|
| **No fragmentation** | Arena resets to empty each frame, memory is contiguous |
| **No leaks possible** | Can't forget to free — reset wipes everything |
| **Bounded memory** | Arena size is our cap, allocated once at init |
| **Fast allocation** | Just bump a pointer, no free lists to manage |
| **No per-object bookkeeping** | ArrayList headers etc. all disappear on reset |
| **Fail-fast** | If arena exhausted, we know immediately |
| **Cache-friendly** | Sequential allocations are contiguous in memory |

### Sizing the Arena

Back-of-envelope for current limits:

```zig
const TRACK_SIZE = @sizeOf(Track) + (64 * @sizeOf(FX)) + (16 * @sizeOf(Send));  // ~20KB
const ITEM_SIZE = @sizeOf(Item) + (8 * @sizeOf(Take));  // ~1KB
const MARKER_SIZE = @sizeOf(Marker);  // ~150 bytes

// For 1024 tracks, 4096 items, 1024 markers:
const ESTIMATED_STATE_SIZE = 
    1024 * TRACK_SIZE +   // ~20MB
    4096 * ITEM_SIZE +    // ~4MB  
    1024 * MARKER_SIZE +  // ~150KB
    1024 * 1024;          // 1MB overhead for ArrayLists, strings, etc.

// ~25MB per arena, 50MB total for double buffer
// Add headroom: 64MB per arena = 128MB total
const ARENA_SIZE = 64 * 1024 * 1024;
```

That sounds like a lot, but:

1. It's allocated once at plugin init
2. It's virtual memory — OS only commits pages you touch
3. Small projects only touch a fraction of it
4. It *guarantees* we never fail mid-frame

### State Structs Become Slice-Based

```zig
pub const State = struct {
    tracks: []Track,      // Allocated from arena
    items: []Item,        // Allocated from arena  
    markers: []Marker,    // Allocated from arena
    
    pub fn empty() State {
        return .{
            .tracks = &.{},
            .items = &.{},
            .markers = &.{},
        };
    }
};

fn pollTracks(alloc: Allocator, api: anytype) ![]Track {
    const count = api.getTrackCount();
    const tracks = try alloc.alloc(Track, count);
    
    for (tracks, 0..) |*track, i| {
        track.* = pollSingleTrack(alloc, api, i) catch continue;
    }
    
    return tracks;
}

fn pollSingleTrack(alloc: Allocator, api: anytype, idx: usize) !Track {
    const ptr = api.getTrack(idx) orelse return error.TrackNotFound;
    
    // FX and sends also allocated from arena
    const fx_count = api.getFxCount(ptr);
    const fx = try alloc.alloc(FX, fx_count);
    // ... populate fx ...
    
    return Track{
        .name = try alloc.dupe(u8, api.getTrackName(ptr)),
        .fx = fx,
        // ...
    };
}
```

### JSON Serialization Buffer? Also From the Arena

```zig
fn broadcastTracks(alloc: Allocator, state: *const State) void {
    // Allocate JSON buffer from same arena — freed automatically next frame
    const json_buf = alloc.alloc(u8, state.tracks.len * 512) catch return;
    
    const json = serializeTracks(json_buf, state.tracks) orelse return;
    broadcast(json);
    
    // No free needed!
}
```

### The "Never Crash" Properties

1. **All allocation happens at init** — Arena buffers allocated once
2. **Runtime allocation can't fragment** — Reset wipes clean
3. **OOM is recoverable** — Arena exhaustion returns error, doesn't panic
4. **Bounded memory usage** — Can't grow past arena size
5. **No leak accumulation** — Every frame starts fresh

### Caveat: Data That Spans Frames

If something needs to survive across frames (e.g., gesture state, undo coalescing), it can't live in the frame arena:

```zig
const Plugin = struct {
    // Long-lived allocations — use regular allocator
    gesture_state: *GestureState,
    shared_state: *SharedState,
    
    // Per-frame allocations — use arenas
    frame_state: DoubleBufferedState,
    
    pub fn init(backing: Allocator) !*Plugin {
        const self = try backing.create(Plugin);
        self.* = .{
            .gesture_state = try GestureState.init(backing),
            .shared_state = try SharedState.init(backing),
            .frame_state = try DoubleBufferedState.init(backing, ARENA_SIZE),
        };
        return self;
    }
};
```

### Summary

Arenas transform our memory model from "carefully manage N individual allocations" to "two big buffers, ping-pong between them." It's simpler, faster, and arguably *safer* than the current static approach because:

- Static: fixed limits baked into types, can't adapt
- Arena: dynamic within a bounded region, adapts to actual data

We get the flexibility of heap allocation with the predictability of static allocation. For a polling architecture with clear frame boundaries, it's the ideal pattern.

---

## Follow-Up Question

> And arena still makes it possible for us to offer config options e.g. in the menu like max tracks, max markers etc, so users can increase if they have issues or edge cases?

---

## Analysis: Arenas Are *Better* for User-Configurable Limits

Yes, and it's actually *better* for this than fixed arrays.

### Fixed Arrays: Limits Baked Into the Binary

```zig
// Current approach — changing this requires recompilation
const State = struct {
    tracks: [128]Track,    // User wants 256? Tough luck.
    markers: [256]Marker,  // Or recompile the extension.
};
```

### Arena + Config: Limits Are Just Numbers

```zig
pub const Config = struct {
    max_tracks: u32 = 128,
    max_items: u32 = 512,
    max_markers: u32 = 256,
    max_regions: u32 = 256,
    
    // Computed arena size with headroom
    pub fn arenaSize(self: Config) usize {
        const track_bytes = self.max_tracks * @sizeOf(Track) * 2;  // *2 for FX/sends
        const item_bytes = self.max_items * @sizeOf(Item);
        const marker_bytes = self.max_markers * @sizeOf(Marker);
        const region_bytes = self.max_regions * @sizeOf(Region);
        const overhead = 4 * 1024 * 1024;  // 4MB for strings, JSON buffers, etc.
        
        return track_bytes + item_bytes + marker_bytes + region_bytes + overhead;
    }
};
```

### User Changes Settings → Reinitialize Arenas

```zig
const Plugin = struct {
    config: Config,
    frame_state: DoubleBufferedState,
    backing_allocator: Allocator,
    
    pub fn applyConfig(self: *Plugin, new_config: Config) !void {
        // Tear down old arenas
        self.frame_state.deinit(self.backing_allocator);
        
        // Create new ones with updated size
        self.config = new_config;
        self.frame_state = try DoubleBufferedState.init(
            self.backing_allocator,
            new_config.arenaSize(),
        );
        
        // Broadcast to clients that limits changed
        self.broadcastConfigUpdate();
    }
};
```

### Soft Limits with Meaningful Errors

The arena gives us a memory ceiling, but we can enforce *logical* limits with clear feedback:

```zig
fn pollTracks(alloc: Allocator, api: anytype, config: Config) ![]Track {
    const count = api.getTrackCount();
    
    // Soft limit — tell user what's wrong
    if (count > config.max_tracks) {
        broadcastWarning(.{
            .code = "TRACK_LIMIT_EXCEEDED",
            .message = "Project has {} tracks, but limit is {}. Increase in settings.",
            .args = .{ count, config.max_tracks },
        });
        // Continue with truncated list rather than crash
    }
    
    const capped_count = @min(count, config.max_tracks);
    const tracks = try alloc.alloc(Track, capped_count);
    
    // ... poll tracks ...
    
    return tracks;
}
```

### Config Stored/Loaded from REAPER

```zig
// Save to REAPER's ExtState (persists across sessions)
pub fn saveConfig(self: *Plugin, api: anytype) void {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, 
        \\{{"max_tracks":{},"max_items":{},"max_markers":{}}}
    , .{ self.config.max_tracks, self.config.max_items, self.config.max_markers }) catch return;
    
    api.setExtState("Reamo", "Config", json, true);  // true = persist
}

// Load on plugin init
pub fn loadConfig(api: anytype) Config {
    const json = api.getExtState("Reamo", "Config") orelse return Config{};  // defaults
    return parseConfig(json) catch Config{};
}
```

### Menu Integration

```zig
// REAPER action that opens config dialog
fn openConfigDialog(plugin: *Plugin) void {
    // Could be ImGui, native dialog, or web UI in the control surface itself
    const new_config = showConfigDialog(plugin.config);
    
    if (!std.meta.eql(new_config, plugin.config)) {
        plugin.applyConfig(new_config) catch |err| {
            showError("Failed to apply config: {}", .{err});
        };
    }
}
```

### Even Better: Auto-Detect and Warn

```zig
fn pollWithAutoDetect(plugin: *Plugin, api: anytype) void {
    const track_count = api.getTrackCount();
    const item_count = api.getItemCount();
    
    // Track high-water marks
    plugin.stats.max_tracks_seen = @max(plugin.stats.max_tracks_seen, track_count);
    plugin.stats.max_items_seen = @max(plugin.stats.max_items_seen, item_count);
    
    // Proactive warning if approaching limits
    if (track_count > plugin.config.max_tracks * 8 / 10) {  // 80% threshold
        broadcastWarning(.{
            .code = "APPROACHING_TRACK_LIMIT",
            .message = "Using {}/{} tracks. Consider increasing limit.",
            .args = .{ track_count, plugin.config.max_tracks },
        });
    }
}
```

### What the Frontend Might Show

```
┌─ Reamo Settings ─────────────────────────────────┐
│                                                  │
│  Track Limit:    [  256 ▼]   (current: 47)      │
│  Item Limit:     [ 1024 ▼]   (current: 892)  ⚠  │
│  Marker Limit:   [  256 ▼]   (current: 12)      │
│  Region Limit:   [  256 ▼]   (current: 8)       │
│                                                  │
│  Memory Usage:   23 MB / 64 MB                   │
│                                                  │
│  ⚠ Item count approaching limit                 │
│                                                  │
│  [Apply]  [Reset to Defaults]                    │
└──────────────────────────────────────────────────┘
```

### Comparison Summary

| Aspect | Fixed Arrays | Arena + Config |
|--------|--------------|----------------|
| Change limits | Recompile | Runtime, persisted |
| User feedback | Silent truncation or crash | Clear warnings |
| Memory usage | Always max | Proportional to config |
| Edge cases | "File a bug report" | "Increase limit in settings" |
| Power users | Stuck with our guesses | Self-service |

The arena doesn't care *why* it's a certain size — we compute the size from config, allocate once, and the rest of our code just uses the allocator. The limits become data instead of types.

---

## Conclusion

Given REAPER's philosophy of "audio production without limits," adopting arena-based allocation with user-configurable limits aligns our control surface with that ethos. Users with massive orchestral templates (1000+ tracks) can increase limits; users on constrained devices can decrease them. The architecture handles both gracefully.

**Next steps:**

1. Prototype `DoubleBufferedState` with arena allocators
2. Add `Config` struct with `arenaSize()` calculation
3. Implement REAPER ExtState persistence for config
4. Add settings UI (REAPER menu action or web UI in control surface)
5. Add soft limit warnings with clear user messaging
