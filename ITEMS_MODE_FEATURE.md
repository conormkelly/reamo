# Items Mode Feature Specification

This document captures the complete plan for implementing the Items Mode feature, including waveform/peaks display via the `GetMediaItemTake_Peaks` API.

## Overview

### Rationale

The current app shows regions (song structure) but not what's actually recorded in them. Users must go to the computer to see/manage takes. This breaks the "stay at instrument" workflow.

### What This Is

- View items within a time selection or region
- See waveform visualization for audio items
- Switch between takes
- Quick keep/trash decisions
- Visual organization (color, notes)

### What This Is NOT

- No comping lanes
- No crossfades
- No waveform editing
- No split/glue
- No detailed MIDI editing

Just: **"See what I recorded, tidy it up, make quick keep/trash decisions, move on."**

---

## Current State

### Already Implemented

| Component | Location | Status |
|-----------|----------|--------|
| Items polling | [main.zig:270-278](extension/src/main.zig#L270-L278) | ✅ Polls every 30ms |
| Items state | [items.zig](extension/src/items.zig) | ✅ Item/Take structs, JSON serialization |
| Items event | API.md | ✅ Broadcasts when items change |
| Item commands | [commands/items.zig](extension/src/commands/items.zig) | ✅ setActiveTake, move, color, lock, notes, delete, goto, select |
| Take commands | [commands/takes.zig](extension/src/commands/takes.zig) | ✅ next, prev, delete, cropToActive |

### Currently Missing

| Feature | Notes |
|---------|-------|
| Item/Take GUIDs in events | Need stable IDs for frontend caching |
| `item/getPeaks` command | On-demand waveform data |
| MIDI item detection | Filter out MIDI before requesting peaks |
| GetMediaItemTake_Peaks binding | REAPER API not yet bound |
| TakeIsMIDI binding | REAPER API not yet bound |
| AudioAccessor bindings | For cache invalidation detection |
| Items in initial snapshot | Items not sent on connect |
| Remove time selection filter | Currently only sends items overlapping time selection |

### Architecture Decision: Send All Items

**Decision:** Remove the backend time selection filter. Send ALL items to frontend.

**Rationale:**
- Frontend needs all items for LOD overview (colored bars showing "stuff here")
- Frontend can filter by time selection when needed (simple JS filter)
- Avoids round-trip when switching views
- Simpler to test - one consistent event format
- Data size is acceptable (~5-60KB for typical projects)

**Changes required:**
1. Remove time selection filter in `items.zig` `State.poll()`
2. Add items to initial snapshot in `main.zig`
3. Frontend filters as needed: `items.filter(i => overlaps(i, timeSel))`

---

## REAPER API Reference

### GetMediaItemTake_Peaks

```c
int GetMediaItemTake_Peaks(
    MediaItem_Take* take,      // Take to get peaks from
    double peakrate,           // Peaks per second of audio
    double starttime,          // Start time (item coordinates, D_STARTOFFS auto-applied)
    int numchannels,           // 1=mono, 2=stereo
    int numsamplesperchannel,  // Number of peak samples to get per channel
    int want_extra_type,       // 0=normal, 115='s' for spectral
    double* buf                // Output buffer
);
```

**Return value encoding:**
- Bits 0-19 (`& 0xFFFFF`): Actual sample count returned
- Bits 20-23 (`>> 20 & 0xF`): Output mode (0=peaks, 1=waveform, 2=MIDI)
- Bit 24 (`& 0x1000000`): Extra type data available

**Buffer layout** (channel-interleaved within blocks):
```
For stereo with numsamplesperchannel=100:

Block 1 - Maximums (indices 0-199):
  [max_L0, max_R0, max_L1, max_R1, ..., max_L99, max_R99]

Block 2 - Minimums (indices 200-399):
  [min_L0, min_R0, min_L1, min_R1, ..., min_L99, min_R99]
```

**Buffer size**: `numsamplesperchannel × numchannels × 2` doubles (×3 with spectral)

**Peak values**: Normalized -1.0 to 1.0

**peakrate calculation**: `peakrate = desired_peaks / item_duration_seconds`

### GUID Retrieval

```c
// Item GUID
GetSetMediaItemInfo_String(item, "GUID", buf, false);

// Take GUID
GetSetMediaItemTakeInfo_String(take, "GUID", buf, false);
```

Returns format: `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}` (38 chars)

### MIDI Detection

```c
bool TakeIsMIDI(MediaItem_Take* take);
```

Check before requesting peaks - MIDI items return output_mode=2 with no useful peak data.

### Channel Count Detection

```c
PCM_source* GetMediaItemTake_Source(MediaItem_Take* take);
int GetMediaSourceNumChannels(PCM_source* source);
```

Use to detect mono vs stereo before requesting peaks:

```zig
const source = api.getMediaItemTake_Source(take) orelse return null;
const num_channels = api.getMediaSourceNumChannels(source);
// Returns 1 for mono, 2 for stereo, 6 for 5.1 surround, etc.

// Cap at stereo for waveform display (ignore surround channels)
const request_channels = @min(num_channels, 2);
```

**Recommendation:** Detect and request actual channel count rather than always requesting stereo. This halves bandwidth for mono sources.

### Cache Invalidation

Use AudioAccessor for precise source change detection:

```c
AudioAccessor* CreateTakeAudioAccessor(MediaItem_Take* take);
bool AudioAccessorStateChanged(AudioAccessor* acc);  // True if source changed
void AudioAccessorValidateState(AudioAccessor* acc);  // Reset change flag
void DestroyAudioAccessor(AudioAccessor* acc);
```

---

## Implementation Plan

> **Note on Phase Numbering:** The phases below align with the Implementation Checklist at the end of this document.

### Phase 1: Backend Foundation

This phase covers all backend changes: API bindings, struct updates, items event changes, and initial snapshot.

#### Step 1a: REAPER API Bindings

**File: `extension/src/reaper.zig`**

Add function pointer fields to `Api` struct:

```zig
// Peaks
getMediaItemTake_Peaks: ?*const fn (
    ?*anyopaque,  // take
    f64,          // peakrate
    f64,          // starttime
    c_int,        // numchannels
    c_int,        // numsamplesperchannel
    c_int,        // want_extra_type
    [*]f64        // buf
) callconv(.c) c_int = null,

// MIDI detection
takeIsMIDI: ?*const fn (?*anyopaque) callconv(.c) bool = null,

// Source and channel info
getMediaItemTake_Source: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
getMediaSourceNumChannels: ?*const fn (?*anyopaque) callconv(.c) c_int = null,

// AudioAccessor (for cache invalidation)
createTakeAudioAccessor: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
audioAccessorStateChanged: ?*const fn (?*anyopaque) callconv(.c) bool = null,
audioAccessorValidateState: ?*const fn (?*anyopaque) callconv(.c) void = null,
destroyAudioAccessor: ?*const fn (?*anyopaque) callconv(.c) void = null,

// Take info string (for GUID)
getSetMediaItemTakeInfo_String: ?*const fn (
    ?*anyopaque,     // take
    [*:0]const u8,   // parmname
    [*]u8,           // buf
    bool             // setNewValue
) callconv(.c) bool = null,
```

Add to `Api.load()`:

```zig
.getMediaItemTake_Peaks = getFunc(info, "GetMediaItemTake_Peaks", ...),
.takeIsMIDI = getFunc(info, "TakeIsMIDI", ...),
.getMediaItemTake_Source = getFunc(info, "GetMediaItemTake_Source", ...),
.getMediaSourceNumChannels = getFunc(info, "GetMediaSourceNumChannels", ...),
.createTakeAudioAccessor = getFunc(info, "CreateTakeAudioAccessor", ...),
.audioAccessorStateChanged = getFunc(info, "AudioAccessorStateChanged", ...),
.audioAccessorValidateState = getFunc(info, "AudioAccessorValidateState", ...),
.destroyAudioAccessor = getFunc(info, "DestroyAudioAccessor", ...),
.getSetMediaItemTakeInfo_String = getFunc(info, "GetSetMediaItemTakeInfo_String", ...),
```

Add wrapper methods:

```zig
/// Check if take contains MIDI data
pub fn isTakeMIDI(self: *const Api, take: *anyopaque) bool {
    const f = self.takeIsMIDI orelse return false;
    return f(take);
}

/// Get take GUID string
pub fn getTakeGUID(self: *const Api, take: *anyopaque, buf: []u8) []const u8 {
    const f = self.getSetMediaItemTakeInfo_String orelse return "";
    if (f(take, "GUID", buf.ptr, false)) {
        return std.mem.sliceTo(buf, 0);
    }
    return "";
}

/// Get item GUID string
/// Note: getSetMediaItemInfo_String is ALREADY bound in reaper.zig - verified
pub fn getItemGUID(self: *const Api, item: *anyopaque, buf: []u8) []const u8 {
    const f = self.getSetMediaItemInfo_String orelse return "";
    if (f(item, "GUID", buf.ptr, false)) {
        return std.mem.sliceTo(buf, 0);
    }
    return "";
}

/// Get the PCM source for a take
pub fn getTakeSource(self: *const Api, take: *anyopaque) ?*anyopaque {
    const f = self.getMediaItemTake_Source orelse return null;
    return f(take);
}

/// Get number of channels in a PCM source (1=mono, 2=stereo, etc.)
pub fn getSourceNumChannels(self: *const Api, source: *anyopaque) c_int {
    const f = self.getMediaSourceNumChannels orelse return 2; // Default to stereo
    return f(source);
}

/// Get take start offset (D_STARTOFFS) - how much of the source is trimmed from the start
pub fn getTakeStartOffset(self: *const Api, take: *anyopaque) f64 {
    const f = self.getSetMediaItemTakeInfo_Value orelse return 0.0;
    return f(take, "D_STARTOFFS", 0.0, false);
}

/// Get take playrate (D_PLAYRATE) - 1.0 = normal speed, 2.0 = double speed, etc.
pub fn getTakePlayrate(self: *const Api, take: *anyopaque) f64 {
    const f = self.getSetMediaItemTakeInfo_Value orelse return 1.0;
    return f(take, "D_PLAYRATE", 0.0, false);
}

/// Get peak data for a take's audio source
/// Returns: encoded result (bits 0-19: sample count, bits 20-23: mode)
/// Returns null if API not available
pub fn getMediaItemTakePeaks(
    self: *const Api,
    take: *anyopaque,
    peakrate: f64,
    starttime: f64,
    numchannels: c_int,
    numsamplesperchannel: c_int,
    want_extra_type: c_int,
    buf: [*]f64,
) ?c_int {
    const f = self.getMediaItemTake_Peaks orelse return null;
    return f(take, peakrate, starttime, numchannels, numsamplesperchannel, want_extra_type, buf);
}
```

**Note on existing bindings:** `getSetMediaItemInfo_String` and `getSetMediaItemTakeInfo_Value` are already bound in `reaper.zig`. Only the new function pointers listed above need to be added.

#### Step 1b: Add GUIDs and isMIDI to Items Event

**File: `extension/src/items.zig`**

Update `Take` struct (add GUID and isMIDI fields):

```zig
pub const Take = struct {
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    is_active: bool = false,

    // NEW: Stable identifier for caching
    guid: [40]u8 = undefined,
    guid_len: usize = 0,

    // NEW: MIDI detection (frontend can skip peaks request)
    is_midi: bool = false,

    pub fn getName(self: *const Take) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getGUID(self: *const Take) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn eql(self: *const Take, other: *const Take) bool {
        if (self.is_active != other.is_active) return false;
        if (self.is_midi != other.is_midi) return false;  // NEW
        if (self.name_len != other.name_len) return false;
        if (self.guid_len != other.guid_len) return false;  // NEW
        if (!std.mem.eql(u8, self.getName(), other.getName())) return false;
        if (!std.mem.eql(u8, self.getGUID(), other.getGUID())) return false;  // NEW
        return true;
    }
};
```

Update `Item` struct (add GUID field):

```zig
pub const Item = struct {
    // Identity
    track_idx: c_int = 0,
    item_idx: c_int = 0,

    // NEW: Stable identifier for caching
    guid: [40]u8 = undefined,
    guid_len: usize = 0,

    // Position and length
    position: f64 = 0,
    length: f64 = 0,

    // Properties
    color: c_int = 0,
    locked: bool = false,
    selected: bool = false,
    active_take_idx: c_int = 0,

    // Notes (truncated to fit)
    notes: [1024]u8 = undefined,
    notes_len: usize = 0,

    // Takes
    takes: [MAX_TAKES_PER_ITEM]Take = undefined,
    take_count: usize = 0,

    pub fn getNotes(self: *const Item) []const u8 {
        return self.notes[0..self.notes_len];
    }

    pub fn getGUID(self: *const Item) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn eql(self: *const Item, other: *const Item) bool {
        if (self.track_idx != other.track_idx) return false;
        if (self.item_idx != other.item_idx) return false;
        if (self.guid_len != other.guid_len) return false;  // NEW
        if (!std.mem.eql(u8, self.getGUID(), other.getGUID())) return false;  // NEW
        if (@abs(self.position - other.position) > 0.001) return false;
        if (@abs(self.length - other.length) > 0.001) return false;
        if (self.color != other.color) return false;
        if (self.locked != other.locked) return false;
        if (self.selected != other.selected) return false;
        if (self.active_take_idx != other.active_take_idx) return false;
        if (self.notes_len != other.notes_len) return false;
        if (!std.mem.eql(u8, self.getNotes(), other.getNotes())) return false;
        if (self.take_count != other.take_count) return false;

        for (0..self.take_count) |i| {
            if (!self.takes[i].eql(&other.takes[i])) return false;
        }
        return true;
    }
};
```

Update `State.poll()` to fetch GUIDs and isMIDI, and **remove time selection filter**:

```zig
pub fn poll(api: *const reaper.Api) State {
    var state = State{};

    // REMOVED: time selection - it's project-level state included in transport event
    // Frontend gets timeSelection from transport event payload, not items event

    // Enumerate all tracks
    const track_count = api.trackCount();
    var track_idx: c_int = 0;
    while (track_idx < track_count) : (track_idx += 1) {
        const track = api.getTrackByIdx(track_idx) orelse continue;

        // Enumerate items on this track
        const item_count = api.trackItemCount(track);
        var item_idx: c_int = 0;
        while (item_idx < item_count) : (item_idx += 1) {
            if (state.item_count >= MAX_ITEMS) break;

            const item_ptr = api.getItemByIdx(track, item_idx) orelse continue;

            const pos = api.getItemPosition(item_ptr);
            const len = api.getItemLength(item_ptr);
            // REMOVED: time selection filter - send ALL items now

            var item = &state.items[state.item_count];
            item.track_idx = track_idx;
            item.item_idx = item_idx;
            item.position = pos;
            item.length = len;
            item.color = api.getItemColor(item_ptr);
            item.locked = api.getItemLocked(item_ptr);
            item.selected = api.getItemSelected(item_ptr);
            item.active_take_idx = api.getItemActiveTakeIdx(item_ptr);

            // NEW: Get item GUID
            var guid_buf: [40]u8 = undefined;
            const guid = api.getItemGUID(item_ptr, &guid_buf);
            @memcpy(item.guid[0..guid.len], guid);
            item.guid_len = guid.len;

            // Get notes
            var notes_buf: [1024]u8 = undefined;
            const notes = api.getItemNotes(item_ptr, &notes_buf);
            const notes_copy_len = @min(notes.len, item.notes.len);
            @memcpy(item.notes[0..notes_copy_len], notes[0..notes_copy_len]);
            item.notes_len = notes_copy_len;

            // Enumerate takes
            const take_count: usize = @intCast(@max(0, api.itemTakeCount(item_ptr)));
            item.take_count = @min(take_count, MAX_TAKES_PER_ITEM);

            for (0..item.take_count) |take_idx| {
                const take_ptr = api.getTakeByIdx(item_ptr, @intCast(take_idx)) orelse continue;
                var take = &item.takes[take_idx];

                const take_name = api.getTakeNameStr(take_ptr);
                const name_copy_len = @min(take_name.len, take.name.len);
                @memcpy(take.name[0..name_copy_len], take_name[0..name_copy_len]);
                take.name_len = name_copy_len;
                take.is_active = (take_idx == @as(usize, @intCast(item.active_take_idx)));

                // NEW: Get take GUID
                const take_guid = api.getTakeGUID(take_ptr, &guid_buf);
                @memcpy(take.guid[0..take_guid.len], take_guid);
                take.guid_len = take_guid.len;

                // NEW: Check if MIDI
                take.is_midi = api.isTakeMIDI(take_ptr);
            }

            state.item_count += 1;
        }

        if (state.item_count >= MAX_ITEMS) break;
    }

    return state;
}
```

Update `itemsToJson()` to include GUIDs and isMIDI:

```zig
pub fn itemsToJson(self: *const State, buf: []u8) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // SIMPLIFIED: No timeSelection here - frontend gets it from transport event
    w.writeAll("{\"type\":\"event\",\"event\":\"items\",\"payload\":{\"items\":[") catch return null;

    for (0..self.item_count) |i| {
        if (i > 0) w.writeByte(',') catch return null;
        const item = &self.items[i];

        // NEW: Include guid after itemIdx
        w.print("{{\"trackIdx\":{d},\"itemIdx\":{d},\"guid\":\"", .{
            item.track_idx, item.item_idx
        }) catch return null;
        protocol.writeJsonString(w, item.getGUID()) catch return null;
        w.print("\",\"position\":{d:.3},\"length\":{d:.3},", .{
            item.position, item.length
        }) catch return null;
        w.print("\"color\":{d},\"locked\":{},\"selected\":{},\"activeTakeIdx\":{d},\"notes\":\"", .{
            item.color, item.locked, item.selected, item.active_take_idx
        }) catch return null;
        protocol.writeJsonString(w, item.getNotes()) catch return null;
        w.writeAll("\",\"takes\":[") catch return null;

        for (0..item.take_count) |t| {
            if (t > 0) w.writeByte(',') catch return null;
            const take = &item.takes[t];
            // NEW: Include guid and isMIDI for each take
            w.writeAll("{\"name\":\"") catch return null;
            protocol.writeJsonString(w, take.getName()) catch return null;
            w.writeAll("\",\"guid\":\"") catch return null;
            protocol.writeJsonString(w, take.getGUID()) catch return null;
            w.print("\",\"isActive\":{},\"isMIDI\":{}}}", .{take.is_active, take.is_midi}) catch return null;
        }

        w.writeAll("]}") catch return null;
    }

    w.writeAll("]}}") catch return null;
    return stream.getWritten();
}
```

#### Step 1c: Add Items to Initial Snapshot

**File: `extension/src/main.zig`**

In `processTimerCallback()`, add items to the initial snapshot section (around line 204-231):

```zig
// Send to each new client
for (snapshot_clients[0..snapshot_count]) |client_id| {
    // ... existing transport, project, markers, regions, tracks ...

    // NEW: Items snapshot
    var buf_items: [32768]u8 = undefined;
    const current_items_snapshot = items.State.poll(api);
    if (current_items_snapshot.itemsToJson(&buf_items)) |json| {
        shared_state.sendToClient(client_id, json);
    }
}
```

### Phase 2: Peaks Command

**File: `extension/src/commands/items.zig`**

Add to handlers array:

```zig
.{ .name = "item/getPeaks", .handler = handleItemGetPeaks },
```

Implement handler:

```zig
const MAX_PEAKS = 2000;  // Reasonable upper limit

fn handleItemGetPeaks(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // 1. Get item from trackIdx, itemIdx
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    // 2. Get requested peak count (default 400)
    const width = cmd.getInt("width") orelse 400;
    if (width <= 0 or width > MAX_PEAKS) {
        response.err("INVALID_WIDTH", "Width must be 1-2000");
        return;
    }

    // 3. Get active take
    const take = api.getItemActiveTake(item_info.item) orelse {
        response.err("NO_TAKE", "Item has no active take");
        return;
    };

    // 4. Check if MIDI
    if (api.isTakeMIDI(take)) {
        response.err("MIDI_ITEM", "Cannot get peaks for MIDI items");
        return;
    }

    // 5. Get source and detect channel count
    const source = api.getTakeSource(take) orelse {
        response.err("NO_SOURCE", "Take has no source");
        return;
    };
    const source_channels = api.getSourceNumChannels(source);
    // Cap at stereo for waveform display (ignore surround channels)
    const num_channels: c_int = @min(source_channels, 2);
    if (num_channels == 0) {
        response.err("NO_CHANNELS", "Source has no channels");
        return;
    }

    // 6. Get item properties
    const length = api.getItemLength(item_info.item);
    if (length <= 0) {
        response.err("EMPTY_ITEM", "Item has zero length");
        return;
    }

    // 7. Calculate peakrate
    const num_peaks: c_int = @intCast(width);
    const peakrate = @as(f64, @floatFromInt(num_peaks)) / length;

    // 8. Allocate buffer (max+min blocks for detected channel count)
    var buf: [MAX_PEAKS * 2 * 2]f64 = undefined;  // Max size for stereo
    const buf_size: usize = @intCast(num_peaks * num_channels * 2);

    // 9. Call GetMediaItemTake_Peaks with detected channel count
    // NOTE: Uses wrapper method getMediaItemTakePeaks (camelCase, no underscore)
    const rv = api.getMediaItemTakePeaks(take, peakrate, 0, num_channels, num_peaks, 0, buf[0..buf_size].ptr) orelse {
        response.err("API_ERROR", "GetMediaItemTake_Peaks not available");
        return;
    };

    // 10. Parse return value
    const sample_count: usize = @intCast(rv & 0xFFFFF);
    const output_mode = (rv >> 20) & 0xF;

    if (sample_count == 0 or output_mode == 2) {
        response.err("NO_PEAKS", "No peak data available");
        return;
    }

    // 11. Get GUIDs for cache key
    var item_guid_buf: [40]u8 = undefined;
    var take_guid_buf: [40]u8 = undefined;
    const item_guid = api.getItemGUID(item_info.item, &item_guid_buf);
    const take_guid = api.getTakeGUID(take, &take_guid_buf);

    // 12. Serialize response with detected channel count
    const channels: usize = @intCast(num_channels);
    var response_buf: [32768]u8 = undefined;
    const json = serializePeaksResponse(
        &response_buf,
        item_guid,
        take_guid,
        length,
        api.getTakeStartOffset(take),
        api.getTakePlayrate(take),
        sample_count,
        channels,
        buf[0 .. sample_count * channels * 2]
    ) orelse {
        response.err("SERIALIZE_ERROR", "Failed to serialize peaks");
        return;
    };

    // ResponseWriter.success() expects the PAYLOAD JSON only (not the full response envelope).
    // It wraps the payload in: {"type":"response","id":"...","success":true,"payload":<your_json>}
    response.success(json);
}

fn serializePeaksResponse(
    buf: []u8,
    item_guid: []const u8,
    take_guid: []const u8,
    length: f64,
    start_offset: f64,
    playrate: f64,
    sample_count: usize,
    channels: usize,
    peak_buf: []const f64,
) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    w.writeAll("{\"itemGUID\":\"") catch return null;
    w.writeAll(item_guid) catch return null;
    w.writeAll("\",\"takeGUID\":\"") catch return null;
    w.writeAll(take_guid) catch return null;
    w.print("\",\"length\":{d:.6},\"startOffset\":{d:.6},\"playrate\":{d:.6},", .{
        length, start_offset, playrate
    }) catch return null;
    w.print("\"channels\":{d},\"peaks\":[", .{channels}) catch return null;

    // Write peaks as [min,max] pairs
    // Buffer layout: [max_L0,max_R0,...] then [min_L0,min_R0,...]
    const max_block = peak_buf[0 .. sample_count * channels];
    const min_block = peak_buf[sample_count * channels .. sample_count * channels * 2];

    for (0..sample_count) |i| {
        if (i > 0) w.writeByte(',') catch return null;

        if (channels == 2) {
            // Stereo: output as {"l":[min,max],"r":[min,max]}
            const max_l = max_block[i * 2];
            const max_r = max_block[i * 2 + 1];
            const min_l = min_block[i * 2];
            const min_r = min_block[i * 2 + 1];
            w.print("{{\"l\":[{d:.4},{d:.4}],\"r\":[{d:.4},{d:.4}]}}", .{
                min_l, max_l, min_r, max_r
            }) catch return null;
        } else {
            // Mono: output as [min,max]
            const max_val = max_block[i];
            const min_val = min_block[i];
            w.print("[{d:.4},{d:.4}]", .{min_val, max_val}) catch return null;
        }
    }

    w.writeAll("]}") catch return null;
    return stream.getWritten();
}
```

### Phase 3: API Documentation

**File: `extension/API.md`**

Add to Item Commands section:

```markdown
### `item/getPeaks`

Get waveform peak data for an item's active take. Use for waveform visualization.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `trackIdx` | int | Yes | Track index (0-based) |
| `itemIdx` | int | Yes | Item index within track (0-based) |
| `width` | int | No | Number of peaks to return (default: 400, max: 2000) |

```json
{"type": "command", "command": "item/getPeaks", "trackIdx": 0, "itemIdx": 0, "width": 800, "id": "1"}
```

**Response:**

```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "itemGUID": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
    "takeGUID": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
    "length": 5.0,
    "startOffset": 0.0,
    "playrate": 1.0,
    "channels": 2,
    "peaks": [
      {"l": [-0.5, 0.6], "r": [-0.4, 0.5]},
      {"l": [-0.7, 0.8], "r": [-0.6, 0.7]},
      ...
    ]
  }
}
```

**Peak format:**
- Stereo: `{"l": [min, max], "r": [min, max]}`
- Mono: `[min, max]`
- Values normalized to -1.0 to 1.0

**Errors:**
- `NOT_FOUND` - Item not found at trackIdx/itemIdx
- `NO_TAKE` - Item has no active take
- `MIDI_ITEM` - Item contains MIDI, not audio
- `NO_SOURCE` - Take has no audio source
- `NO_CHANNELS` - Source has no channels
- `EMPTY_ITEM` - Item has zero length
- `INVALID_WIDTH` - Width out of range (1-2000)
- `NO_PEAKS` - No peak data available (missing/offline source)

**Cache key:** Frontend should cache using `{itemGUID, takeGUID, length, startOffset, playrate}`. Re-fetch when any of these change in the `items` event.
```

Update Items Event section to include GUIDs:

```markdown
### `items` Event

```json
{
  "type": "event",
  "event": "items",
  "payload": {
    "items": [
      {
        "trackIdx": 0,
        "itemIdx": 0,
        "guid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
        "position": 10.000,
        "length": 5.000,
        "color": 0,
        "locked": false,
        "selected": false,
        "activeTakeIdx": 0,
        "notes": "",
        "takes": [
          {
            "name": "Take 1",
            "guid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
            "isActive": true,
            "isMIDI": false
          }
        ]
      }
    ]
  }
}
```
```

---

## Implementation Notes

### ResponseWriter Contract

The `ResponseWriter` in `commands/mod.zig` handles response formatting:

```zig
// ResponseWriter.success(payload) expects ONLY the payload JSON.
// It wraps it in: {"type":"response","id":"...","success":true,"payload":<your_json>}
response.success("{\"foo\":123}");
// Produces: {"type":"response","id":"1","success":true,"payload":{"foo":123}}

// ResponseWriter.err(code, message) handles error responses.
response.err("NOT_FOUND", "Item not found");
// Produces: {"type":"response","id":"1","success":false,"error":{"code":"NOT_FOUND","message":"Item not found"}}
```

### Existing Bindings (Already in reaper.zig)

These bindings already exist and do NOT need to be added:
- `getSetMediaItemInfo_String` - used for item GUID
- `getSetMediaItemTakeInfo_Value` - used for D_STARTOFFS and D_PLAYRATE

### Wrapper Method Naming Convention

Raw function pointer fields use REAPER's naming (e.g., `getMediaItemTake_Peaks`).
Wrapper methods use camelCase without underscores (e.g., `getMediaItemTakePeaks`).

---

## Data Structures

### Peak Response (JSON)

```typescript
interface PeaksResponse {
  itemGUID: string;      // Stable item identifier
  takeGUID: string;      // Stable take identifier
  length: number;        // Item length in seconds (D_LENGTH)
  startOffset: number;   // Take start offset (D_STARTOFFS)
  playrate: number;      // Take playrate (D_PLAYRATE)
  channels: 1 | 2;       // Mono or stereo
  peaks: StereoPeak[] | MonoPeak[];
}

// Stereo format
interface StereoPeak {
  l: [min: number, max: number];  // Left channel
  r: [min: number, max: number];  // Right channel
}

// Mono format
type MonoPeak = [min: number, max: number];
```

### Item (in items event)

```typescript
interface Item {
  trackIdx: number;
  itemIdx: number;
  guid: string;           // Stable identifier for caching
  position: number;       // Start position in seconds
  length: number;         // Duration in seconds
  color: number;          // REAPER color value (0 = default)
  locked: boolean;
  selected: boolean;
  activeTakeIdx: number;
  notes: string;
  takes: Take[];
}
```

### Take (in items event)

```typescript
interface Take {
  name: string;
  guid: string;           // Stable identifier for caching
  isActive: boolean;
  isMIDI: boolean;        // If true, skip peaks request - show MIDI indicator instead
}
```

### Frontend Cache Key

```typescript
interface PeaksCacheKey {
  itemGUID: string;
  takeGUID: string;
  length: number;
  startOffset: number;
  playrate: number;
}

function makeCacheKey(item: Item, take: Take): string {
  return `${item.guid}:${take.guid}:${item.length}:${take.startOffset}:${take.playrate}`;
}
```

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Item with no takes | Return error `NO_TAKE` |
| MIDI item | Return error `MIDI_ITEM` (check TakeIsMIDI first) |
| Take with no source | Return error `NO_SOURCE` |
| Source with 0 channels | Return error `NO_CHANNELS` |
| Zero-length item | Return error `EMPTY_ITEM` |
| Missing/offline source | GetMediaItemTake_Peaks returns 0 samples → `NO_PEAKS` |
| Peak file not built | May block briefly on first request (acceptable) |
| Very long item | Same buffer size regardless - just lower peakrate |
| Mono source | Detected automatically, returns `channels: 1` |
| Surround (5.1, etc.) | Capped to stereo (first 2 channels) |

---

## Cache Invalidation Strategy

### Frontend Cache

Frontend caches peaks by composite key. On each `items` event:

1. For each item in the event, compare against cached key
2. If `{itemGUID, takeGUID, length, startOffset, playrate}` changed, invalidate
3. If item is currently visible and cache invalidated, re-fetch peaks

### Source File Changes

For detecting source file edits (rare for control surface use case):

1. Extension could poll `AudioAccessorStateChanged()` for visible items
2. Broadcast a `peaksInvalidated` event if source changed
3. Frontend re-fetches affected items

**Deferred:** Source change detection is low priority. Most control surface workflows don't edit source files while using the remote.

---

## Performance Characteristics

| Metric | Value |
|--------|-------|
| Typical peaks request | 400-1000 peaks |
| Response size (stereo) | ~5-15 KB JSON |
| Response size (mono) | ~2.5-7.5 KB JSON (half of stereo) |
| REAPER API latency | Microseconds (reads cached .reapeaks) |
| Safe to call in 30ms timer | Yes |
| Maximum peaks per request | 2000 (enforced) |
| Buffer memory | 32 KB max (2000 × 2 × 2 × 8 bytes) |

---

## UI Concept (Frontend - Future Phase)

```
┌─────────────────────────────────────────────────────┐
│ Track: Guitar ▼              [Time Selection]       │
├─────────────────────────────────────────────────────┤
│                                                     │
│    ┌─────────────┐              ┌─────────────┐    │
│    │     1/3     │              │     2/3     │    │
│    │ ▓▓▓▓▓▓▓▓▓▓▓ │              │ ▓▓▓▓▓▓▓▓▓▓▓ │    │
│    └─────────────┘              └─────────────┘    │
│         ▲                                          │
│     (selected)                                     │
├─────────────────────────────────────────────────────┤
│ Take 1 of 3  [◀][▶]  [Crop] [🗑] [Notes] [Color]   │
└─────────────────────────────────────────────────────┘
```

Key decisions:
- Show ONE track at a time
- Items shown as waveform bars with take count badge
- ItemInfoBar for selected item: take switching, actions
- Track dropdown filters to tracks with items in time selection

---

## Testing Plan

### WebSocket Testing (websocat)

**Phase 1: Verify items event has GUIDs and isMIDI**

```bash
# Get token
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken")

# Connect and observe items event in initial snapshot
# Should see: guid on items, guid + isMIDI on takes, NO timeSelection in payload
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 1) | websocat ws://localhost:9224
```

Expected items event format:
```json
{"type":"event","event":"items","payload":{"items":[{"trackIdx":0,"itemIdx":0,"guid":"{...}","position":...,"takes":[{"name":"...","guid":"{...}","isActive":true,"isMIDI":false}]}]}}
```

**Phase 2: Test item/getPeaks command**

```bash
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken")

# Request peaks for first item on first track
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 0.2
 echo '{"type":"command","command":"item/getPeaks","trackIdx":0,"itemIdx":0,"width":100,"id":"1"}'
 sleep 0.5) | websocat ws://localhost:9224
```

### Unit Tests (extension)

- `test "getPeaks returns valid JSON for stereo audio item"`
- `test "getPeaks returns valid JSON for mono audio item"`
- `test "getPeaks returns channels:1 for mono, channels:2 for stereo"`
- `test "getPeaks returns MIDI_ITEM error for MIDI"`
- `test "getPeaks returns NO_TAKE for empty item"`
- `test "getPeaks returns NO_SOURCE for take without source"`
- `test "peak buffer layout is correct for mono"`
- `test "peak buffer layout is correct for stereo"`
- `test "GUID retrieval works"`

### Integration Tests

1. Create project with stereo audio item
2. Request peaks via WebSocket
3. Verify response contains `channels: 2` and valid stereo peak data
4. Add mono audio item to project
5. Request peaks for mono item
6. Verify response contains `channels: 1` and valid mono peak data
7. Modify item (change length)
8. Verify items event shows updated properties
9. Re-request peaks, verify cache key changed

---

## Implementation Checklist

### Phase 1: Backend Foundation
- [ ] Add GetMediaItemTake_Peaks binding to reaper.zig
- [ ] Add TakeIsMIDI binding
- [ ] Add GetMediaItemTake_Source binding
- [ ] Add GetMediaSourceNumChannels binding
- [ ] Add GetSetMediaItemTakeInfo_String binding (for take GUID)
- [ ] Add wrapper methods for new APIs
- [ ] Add GUIDs to Item and Take structs in items.zig
- [ ] Add isMIDI field to Take struct
- [ ] Remove time_sel_start/time_sel_end from items.State struct (transport.zig has its own)
- [ ] Update items.State.poll() to fetch GUIDs and isMIDI
- [ ] Remove time selection filter from items.State.poll() (send ALL items)
- [ ] Update itemsToJson() to remove timeSelection, add GUIDs and isMIDI
- [ ] Add items to initial snapshot in main.zig
- [ ] Build and test with websocat - verify items event format

### Phase 2: Peaks Command
- [ ] Implement handleItemGetPeaks in commands/items.zig
- [ ] Implement serializePeaksResponse helper
- [ ] Add channel count detection (mono vs stereo)
- [ ] Add to handlers array
- [ ] Test with websocat (mono and stereo items)
- [ ] Handle edge cases (MIDI, empty, missing source, no channels)

### Phase 3: Documentation
- [ ] Update API.md with item/getPeaks command
- [ ] Update items event documentation with GUIDs
- [ ] Document cache key strategy

### Phase 4: Frontend (Separate Feature)
- [ ] Items slice in Zustand store
- [ ] Peaks cache with invalidation
- [ ] ItemsTimeline component
- [ ] Waveform canvas rendering
- [ ] ItemInfoBar component
