const std = @import("std");
const utf8 = @import("../core/utf8.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const tracks = @import("tracks.zig");

/// The track and FX a preset or bypass command names. The track is found by
/// trackIdx or trackGuid, the FX by fxGuid when given, else by fxIdx: an
/// FX's index changes when the chain is reordered, its GUID doesn't. On
/// failure answers the error and returns null; `out_of_range` is the error
/// code for an fxIdx past the chain.
const FxTarget = struct { track: *anyopaque, track_idx: c_int, fx_idx: c_int };

fn resolveFxTarget(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter, comptime out_of_range: []const u8) ?FxTarget {
    if (cmd.getInt("trackIdx") == null and cmd.getString("trackGuid") == null) {
        response.err("MISSING_TRACK_IDX", "trackIdx or trackGuid is required");
        return null;
    }
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return null;
    };
    if (cmd.getString("fxGuid")) |fx_guid| {
        const fx_idx = findFxByGuid(api, resolution.track, fx_guid) orelse {
            response.err("NOT_FOUND", "FX not found");
            return null;
        };
        return .{ .track = resolution.track, .track_idx = resolution.idx, .fx_idx = fx_idx };
    }
    const fx_idx = cmd.getInt("fxIdx") orelse {
        response.err("MISSING_FX_IDX", "fxIdx or fxGuid is required");
        return null;
    };
    if (fx_idx < 0 or fx_idx >= api.trackFxCount(resolution.track)) {
        response.err(out_of_range, "FX not found");
        return null;
    }
    return .{ .track = resolution.track, .track_idx = resolution.idx, .fx_idx = fx_idx };
}

/// Navigate to next preset for the specified FX
/// Params: see resolveFxTarget
pub fn handlePresetNext(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const target = resolveFxTarget(api, cmd, response, "NOT_FOUND") orelse return;
    const track = target.track;
    const track_idx = target.track_idx;
    const fx_idx = target.fx_idx;

    // Loading a preset rewrites the plugin's state; Ctrl+Z should return
    // to the sound before it. (REAPER drops the point if nothing changed.)
    api.undoBeginBlock();
    const success = api.trackFxNavigatePresets(track, fx_idx, 1);
    api.undoEndBlock("REAmo: Change FX preset");
    if (!success) {
        response.err("NAVIGATE_FAILED", "Failed to navigate to next preset");
        return;
    }

    logging.debug("FX preset next: track {} fx {}", .{ track_idx, fx_idx });
}

/// Navigate to previous preset for the specified FX
/// Params: see resolveFxTarget
pub fn handlePresetPrev(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const target = resolveFxTarget(api, cmd, response, "NOT_FOUND") orelse return;
    const track = target.track;
    const track_idx = target.track_idx;
    const fx_idx = target.fx_idx;

    // Loading a preset rewrites the plugin's state; Ctrl+Z should return
    // to the sound before it. (REAPER drops the point if nothing changed.)
    api.undoBeginBlock();
    const success = api.trackFxNavigatePresets(track, fx_idx, -1);
    api.undoEndBlock("REAmo: Change FX preset");
    if (!success) {
        response.err("NAVIGATE_FAILED", "Failed to navigate to previous preset");
        return;
    }

    logging.debug("FX preset prev: track {} fx {}", .{ track_idx, fx_idx });
}

/// Set preset by index for the specified FX
/// Params: see resolveFxTarget, and presetIdx (-1=default user, -2=factory, 0+=preset index)
pub fn handlePresetSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const target = resolveFxTarget(api, cmd, response, "NOT_FOUND") orelse return;
    const track = target.track;
    const track_idx = target.track_idx;
    const fx_idx = target.fx_idx;
    const preset_idx = cmd.getInt("presetIdx") orelse {
        response.err("MISSING_PRESET_IDX", "presetIdx is required (-1=default, -2=factory, or 0+)");
        return;
    };

    // Loading a preset rewrites the plugin's state; Ctrl+Z should return
    // to the sound before it. (REAPER drops the point if nothing changed.)
    api.undoBeginBlock();
    const success = api.trackFxSetPresetByIndex(track, fx_idx, preset_idx);
    api.undoEndBlock("REAmo: Change FX preset");
    if (!success) {
        response.err("SET_FAILED", "Failed to set preset");
        return;
    }

    logging.debug("FX preset set: track {} fx {} preset {}", .{ track_idx, fx_idx, preset_idx });
}

/// Set FX enabled/bypassed state
/// Params: see resolveFxTarget
/// Optional: enabled (0=bypass, 1=enabled) - toggles if omitted
pub fn handleSetEnabled(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const target = resolveFxTarget(api, cmd, response, "INVALID_FX_IDX") orelse return;
    const resolution = tracks.TrackResolution{ .track = target.track, .idx = target.track_idx };
    const fx_idx = target.fx_idx;

    // Get current state for toggle, or use explicit enabled param
    const current = api.trackFxGetEnabled(resolution.track, fx_idx);
    const enabled = cmd.getFlag("enabled") orelse !current;

    // Build undo description with track/FX names
    var track_name_buf: [128]u8 = undefined;
    var fx_name_buf: [128]u8 = undefined;
    var undo_buf: [256:0]u8 = undefined;

    const track_name = api.getTrackNameStr(resolution.track, &track_name_buf);
    const fx_name = api.trackFxGetName(resolution.track, fx_idx, &fx_name_buf);

    const undo_desc: [*:0]const u8 = if (resolution.idx == 0)
        std.fmt.bufPrintZ(&undo_buf, "REAmo: FX bypass toggle: Master: {s}", .{fx_name}) catch "REAmo: FX bypass toggle"
    else
        std.fmt.bufPrintZ(&undo_buf, "REAmo: FX bypass toggle: Track {d} {s}: {s}", .{ resolution.idx, track_name, fx_name }) catch "REAmo: FX bypass toggle";

    api.undoBeginBlock();
    api.trackFxSetEnabled(resolution.track, fx_idx, enabled);
    api.undoEndBlock(undo_desc);

    logging.debug("FX enabled set: track {} fx {} enabled={}", .{ resolution.idx, fx_idx, enabled });
    response.success(null);
}

/// Add an FX to a track by name.
/// Params: trackGuid, fxName, position (optional, -1 = end)
/// Response: { "fxGuid": "{...}", "fxIndex": N }
pub fn handleAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        logging.debug("trackFx/add: track not found", .{});
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        logging.debug("trackFx/add: invalid track pointer", .{});
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    const fx_name = (cmd.getTextAlloc("fxName", std.heap.c_allocator) catch null) orelse {
        logging.debug("trackFx/add: missing fxName", .{});
        response.err("MISSING_PARAM", "fxName is required");
        return;
    };
    defer std.heap.c_allocator.free(fx_name);

    // Build null-terminated name for REAPER API
    var name_buf: [256:0]u8 = undefined;
    const name_len = utf8.copyPrefix(name_buf[0 .. name_buf.len - 1], fx_name);
    name_buf[name_len] = 0;

    // Build undo description
    var undo_buf: [256:0]u8 = undefined;
    const undo_desc: [*:0]const u8 = std.fmt.bufPrintZ(&undo_buf, "REAmo: Add FX: {s}", .{fx_name}) catch "REAmo: Add FX";

    api.undoBeginBlock();
    const fx_idx = addFxAt(api, resolution.track, @ptrCast(&name_buf), cmd.getInt("position"));
    api.undoEndBlock(undo_desc);

    if (fx_idx < 0) {
        logging.warn("trackFx/add: REAPER couldn't add '{f}'", .{logging.untrusted(fx_name)});
        response.err("ADD_FAILED", "Failed to add FX - check FX name");
        return;
    }

    // Get the new FX GUID
    var guid_buf: [64]u8 = undefined;
    const fx_guid = api.trackFxGetGuid(resolution.track, fx_idx, &guid_buf);

    // Build response JSON
    var resp_buf: [256]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"fxGuid\":\"{s}\",\"fxIndex\":{d}}}", .{ fx_guid, fx_idx }) catch {
        response.success(null);
        return;
    };

    logging.debug("trackFx/add: added '{s}' at index {d}, guid={s}", .{ fx_name, fx_idx, fx_guid });
    response.success(resp_json);
}

/// Add an FX by name at `position` and return its index, or -1 if REAPER
/// can't add it. A position that is null, negative or past the end adds at
/// the end.
fn addFxAt(api: anytype, track: *anyopaque, name: [*:0]const u8, position: ?c_int) c_int {
    // Added at the end, then moved: TrackFX_AddByName can insert at N
    // itself (-1000 - N), but REAPER 6.0 appends instead.
    const added = api.trackFxAddByName(track, name, false, -1);
    if (added < 0) return added;
    const pos = position orelse return added;
    if (pos < 0 or pos >= added) return added;
    api.trackFxCopyToTrack(track, added, track, pos, true);
    return pos;
}

/// Delete an FX from a track.
/// Params: trackGuid, fxGuid OR fxIndex
pub fn handleDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        logging.debug("trackFx/delete: track not found", .{});
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        logging.debug("trackFx/delete: invalid track pointer", .{});
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    // Resolve FX by GUID or index
    const fx_idx = resolveFxIndex(api, resolution.track, cmd) orelse {
        logging.debug("trackFx/delete: FX not found", .{});
        response.err("FX_NOT_FOUND", "fxGuid or fxIndex required, or FX not found");
        return;
    };

    // Build undo description
    var fx_name_buf: [128]u8 = undefined;
    const fx_name = api.trackFxGetName(resolution.track, fx_idx, &fx_name_buf);
    var undo_buf: [256:0]u8 = undefined;
    const undo_desc: [*:0]const u8 = std.fmt.bufPrintZ(&undo_buf, "REAmo: Delete FX: {s}", .{fx_name}) catch "REAmo: Delete FX";

    api.undoBeginBlock();
    const success = api.trackFxDelete(resolution.track, fx_idx);
    api.undoEndBlock(undo_desc);

    if (!success) {
        logging.warn("trackFx/delete: TrackFX_Delete failed for index {d}", .{fx_idx});
        response.err("DELETE_FAILED", "Failed to delete FX");
        return;
    }

    logging.debug("trackFx/delete: deleted FX at index {d}", .{fx_idx});
    response.success(null);
}

/// Move an FX to a new position within the same track.
/// Params: trackGuid, fxGuid, toIndex
/// Response: { "newIndex": N }
pub fn handleMove(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        logging.debug("trackFx/move: track not found", .{});
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        logging.debug("trackFx/move: invalid track pointer", .{});
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    // Resolve FX by GUID
    const fx_guid = cmd.getString("fxGuid") orelse {
        logging.debug("trackFx/move: missing fxGuid", .{});
        response.err("MISSING_PARAM", "fxGuid is required");
        return;
    };

    const src_idx = findFxByGuid(api, resolution.track, fx_guid) orelse {
        logging.debug("trackFx/move: FX GUID not found: {f}", .{logging.untrusted(fx_guid)});
        response.err("FX_NOT_FOUND", "FX with given GUID not found");
        return;
    };

    const to_index = cmd.getInt("toIndex") orelse {
        logging.debug("trackFx/move: missing toIndex", .{});
        response.err("MISSING_PARAM", "toIndex is required");
        return;
    };

    // Validate toIndex bounds
    const fx_count = api.trackFxCount(resolution.track);
    if (to_index < 0 or to_index >= fx_count) {
        logging.debug("trackFx/move: toIndex out of range: {d} (count={d})", .{ to_index, fx_count });
        response.err("INVALID_INDEX", "toIndex out of range");
        return;
    }

    if (src_idx == to_index) {
        // No move needed
        var resp_buf: [64]u8 = undefined;
        const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"newIndex\":{d}}}", .{to_index}) catch {
            response.success(null);
            return;
        };
        response.success(resp_json);
        return;
    }

    // Build undo description
    var undo_buf: [256:0]u8 = undefined;
    const undo_desc: [*:0]const u8 = std.fmt.bufPrintZ(&undo_buf, "REAmo: Move FX", .{}) catch "REAmo: Move FX";

    api.undoBeginBlock();
    api.trackFxCopyToTrack(resolution.track, src_idx, resolution.track, to_index, true);
    api.undoEndBlock(undo_desc);

    // Build response
    var resp_buf: [64]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"newIndex\":{d}}}", .{to_index}) catch {
        response.success(null);
        return;
    };

    logging.debug("trackFx/move: moved FX from {d} to {d}", .{ src_idx, to_index });
    response.success(resp_json);
}

/// Fingerprint of an FX's parameter names: `nameHash` in trackFx/getParams
/// responses and trackFxParams events, which must agree for a client to
/// tell whether its cached skeleton is current. Feed it every name in index
/// order, each read into a `name_buf_len` buffer so both truncate alike.
/// Each name is hashed with a terminator, so ["ab", "c"] and ["a", "bc"]
/// differ. The result is kept to 53 bits so the JSON integer is exact as a
/// JavaScript number.
pub const ParamNameHasher = struct {
    wyhash: std.hash.Wyhash = std.hash.Wyhash.init(0),

    /// Buffer size for reading a parameter name to hash.
    pub const name_buf_len = 256;

    pub fn update(self: *ParamNameHasher, name: []const u8) void {
        self.wyhash.update(name);
        self.wyhash.update(&[_]u8{0});
    }

    pub fn final(self: *ParamNameHasher) u64 {
        return self.wyhash.final() & max_safe_json_integer;
    }
};

/// Largest integer a JavaScript number holds exactly (Number.MAX_SAFE_INTEGER).
const max_safe_json_integer: u64 = (1 << 53) - 1;

/// Get all parameter names for an FX (skeleton fetch).
/// Params: trackGuid, fxGuid OR fxIndex
/// Response: { "trackGuid": "...", "fxGuid": "...", "paramCount": N, "nameHash": H, "params": ["name1", "name2", ...] }
/// `nameHash` is the ParamNameHasher result, as trackFxParams events carry it.
pub fn handleGetParams(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        logging.debug("trackFx/getParams: track not found", .{});
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        logging.debug("trackFx/getParams: invalid track pointer", .{});
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    // Resolve FX by GUID or index
    const fx_idx = resolveFxIndex(api, resolution.track, cmd) orelse {
        logging.debug("trackFx/getParams: FX not found", .{});
        response.err("FX_NOT_FOUND", "fxGuid or fxIndex required, or FX not found");
        return;
    };

    // Get FX GUID for response
    var fx_guid_buf: [64]u8 = undefined;
    const fx_guid = api.trackFxGetGuid(resolution.track, fx_idx, &fx_guid_buf);

    // The GUID of the track the request resolved to, by trackIdx or trackGuid
    // ("master" for the master, as clients address it).
    var track_guid_buf: [64]u8 = undefined;
    const track_guid = if (resolution.idx == 0) "master" else api.formatTrackGuid(resolution.track, &track_guid_buf);

    // Get param count
    const param_count = api.trackFxGetNumParams(resolution.track, fx_idx);

    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    // Sized to fit: synths expose thousands of parameters (~20-40 bytes of
    // name each), and the UI awaits this response to open the parameter page.
    const ctx = ParamNamesCtx(@TypeOf(api)){ .api = api, .track = resolution.track, .fx_idx = fx_idx, .track_guid = track_guid, .fx_guid = fx_guid, .param_count = param_count };
    const estimate = 128 + @as(usize, @intCast(@max(param_count, 0))) * 48;
    const json = protocol.writeAlloc(tiered.scratchAllocator(), estimate, ctx, writeParamNames) catch {
        response.err("RESPONSE_TOO_LARGE", "Parameter list too large");
        return;
    };

    logging.debug("trackFx/getParams: returning {d} params for track {s} fx {s}", .{ param_count, track_guid, fx_guid });
    response.successLargePayload(json);
}

fn ParamNamesCtx(comptime Api: type) type {
    return struct { api: Api, track: *anyopaque, fx_idx: c_int, track_guid: []const u8, fx_guid: []const u8, param_count: c_int };
}

fn writeParamNames(ctx: anytype, w: anytype) !void {
    try w.writeAll("{\"trackGuid\":\"");
    try protocol.writeJsonString(w, ctx.track_guid);
    try w.writeAll("\",\"fxGuid\":\"");
    try protocol.writeJsonString(w, ctx.fx_guid);
    try w.print("\",\"paramCount\":{d},\"params\":[", .{ctx.param_count});
    // One read of each name serves both the list and its hash.
    var hasher = ParamNameHasher{};
    var name_buf: [ParamNameHasher.name_buf_len]u8 = undefined;
    var i: c_int = 0;
    while (i < ctx.param_count) : (i += 1) {
        const name = ctx.api.trackFxGetParamName(ctx.track, ctx.fx_idx, i, &name_buf);
        hasher.update(name);
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try protocol.writeJsonString(w, name);
        try w.writeByte('"');
    }
    try w.print("],\"nameHash\":{d}}}", .{hasher.final()});
}

/// Helper: Resolve FX index from fxGuid or fxIndex parameter.
fn resolveFxIndex(api: anytype, track: *anyopaque, cmd: protocol.CommandMessage) ?c_int {
    // Try fxGuid first
    if (cmd.getString("fxGuid")) |fx_guid| {
        return findFxByGuid(api, track, fx_guid);
    }

    // Fall back to fxIndex
    if (cmd.getInt("fxIndex")) |fx_idx| {
        const fx_count = api.trackFxCount(track);
        if (fx_idx >= 0 and fx_idx < fx_count) {
            return fx_idx;
        }
    }

    return null;
}

/// Find FX index by GUID on a track. Public for use by other modules.
pub fn findFxByGuid(api: anytype, track: *anyopaque, target_guid: []const u8) ?c_int {
    const fx_count = api.trackFxCount(track);
    var i: c_int = 0;
    while (i < fx_count) : (i += 1) {
        var guid_buf: [64]u8 = undefined;
        const guid = api.trackFxGetGuid(track, i, &guid_buf);
        if (std.mem.eql(u8, guid, target_guid)) {
            return i;
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "handleSetEnabled requires trackIdx or trackGuid" {
    // Command handlers require ResponseWriter with SharedState.
    // Integration tests via websocat verify full behavior.
    // See mock/mod.zig for MockBackend method tests.
}

test "handleSetEnabled validates fx_idx bounds" {
    // Verifies negative and out-of-range fx_idx returns error.
    // See mock/mod.zig "MockBackend trackFxSetEnabled bounds check" test.
}

test "resolveFxIndex and findFxByGuid compile" {
    // Integration tests via websocat verify full behavior.
}

test "an FX added at a position lands there even where REAPER only appends" {
    const mock = @import("../reaper/mock/mod.zig");
    // The mock appends whatever position it is asked for, as REAPER 6.0 does.
    var m = mock.MockBackend{ .track_count = 1 };
    m.tracks[1].fx[0].setName("ReaComp");
    m.tracks[1].fx[1].setName("ReaVerb");
    m.tracks[1].fx_count = 2;
    const track = m.getTrackByIdx(0).?;

    try std.testing.expectEqual(@as(c_int, 0), addFxAt(&m, track, "ReaEQ", 0));
    try std.testing.expectEqualStrings("ReaEQ", m.tracks[1].fx[0].getName());
    try std.testing.expectEqualStrings("ReaComp", m.tracks[1].fx[1].getName());
    try std.testing.expectEqualStrings("ReaVerb", m.tracks[1].fx[2].getName());

    // Past the end, or no position: at the end.
    try std.testing.expectEqual(@as(c_int, 3), addFxAt(&m, track, "ReaDelay", 7));
    try std.testing.expectEqual(@as(c_int, 4), addFxAt(&m, track, "ReaGate", null));
    try std.testing.expectEqualStrings("ReaGate", m.tracks[1].fx[4].getName());
}

test "trackFx/getParams reports the nameHash its trackFxParams events carry" {
    const mock = @import("../reaper/mock/mod.zig");
    const guid_cache = @import("../state/guid_cache.zig");
    const generator = @import("../subscriptions/trackfxparam_generator.zig");
    const subscriptions = @import("../subscriptions/trackfxparam_subscriptions.zig");
    const alloc = std.testing.allocator;

    var m = mock.MockBackend{ .track_count = 1 };
    m.tracks[1].fx[0].setName("ReaEQ");
    m.tracks[1].fx[0].setParam(0, "Freq", 0.5, "500 Hz");
    m.tracks[1].fx[0].setParam(1, "Gain", 0.5, "0.0 dB");
    m.tracks[1].fx[0].setParam(2, "Q", 0.5, "0.71");
    m.tracks[1].fx_count = 1;
    const track = m.getTrackByIdx(0).?;
    var track_guid_buf: [64]u8 = undefined;
    const track_guid = m.formatTrackGuid(track, &track_guid_buf);
    var fx_guid_buf: [64]u8 = undefined;
    const fx_guid = m.trackFxGetGuid(track, 0, &fx_guid_buf);

    var cache = guid_cache.GuidCache.init(alloc);
    defer cache.deinit();
    try cache.rebuild(&m);
    const client = subscriptions.ClientSubscription{ .active = true, .mode = .range, .range_start = 0, .range_end = 2 };
    const event = try generator.generateParamValues(alloc, &m, &cache, track_guid, fx_guid, &client);
    defer alloc.free(event.json);

    const ctx = ParamNamesCtx(@TypeOf(&m)){ .api = &m, .track = track, .fx_idx = 0, .track_guid = track_guid, .fx_guid = fx_guid, .param_count = 3 };
    const skeleton = try protocol.writeAlloc(alloc, 256, ctx, writeParamNames);
    defer alloc.free(skeleton);

    // Compare the values on the wire, as the client compares them.
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const ev = try std.json.parseFromSlice(struct { payload: struct { nameHash: u64 } }, alloc, event.json, opts);
    defer ev.deinit();
    const sk = try std.json.parseFromSlice(struct { nameHash: ?u64 = null }, alloc, skeleton, opts);
    defer sk.deinit();
    try std.testing.expectEqual(@as(?u64, ev.value.payload.nameHash), sk.value.nameHash);
}

test "an FX whose parameters drop to zero while subscribed gets a valid paramCount 0 event" {
    const mock = @import("../reaper/mock/mod.zig");
    const guid_cache = @import("../state/guid_cache.zig");
    const generator = @import("../subscriptions/trackfxparam_generator.zig");
    const subscriptions = @import("../subscriptions/trackfxparam_subscriptions.zig");
    const alloc = std.testing.allocator;

    var m = mock.MockBackend{ .track_count = 1 };
    m.tracks[1].fx[0].setParam(0, "Freq", 0.5, "500 Hz");
    m.tracks[1].fx[0].setParam(1, "Gain", 0.5, "0.0 dB");
    m.tracks[1].fx_count = 1;
    const track = m.getTrackByIdx(0).?;
    var track_guid_buf: [64]u8 = undefined;
    const track_guid = m.formatTrackGuid(track, &track_guid_buf);
    var fx_guid_buf: [64]u8 = undefined;
    const fx_guid = m.trackFxGetGuid(track, 0, &fx_guid_buf);
    var cache = guid_cache.GuidCache.init(alloc);
    defer cache.deinit();
    try cache.rebuild(&m);
    const client = subscriptions.ClientSubscription{ .active = true, .mode = .range, .range_start = 0, .range_end = 1 };

    const before = try generator.generateParamValues(alloc, &m, &cache, track_guid, fx_guid, &client);
    defer alloc.free(before.json);

    // The plugin reports no parameters any more (VST3 restartComponent).
    m.tracks[1].fx[0].param_count = 0;
    const after = try generator.generateParamValues(alloc, &m, &cache, track_guid, fx_guid, &client);
    defer alloc.free(after.json);

    // A complete event, which the poll sends because it differs from the last one.
    try std.testing.expect(after.json.len > 0);
    try std.testing.expect(generator.hashParamValues(after.json) != generator.hashParamValues(before.json));
    const Payload = struct { trackGuid: []const u8, fxGuid: []const u8, paramCount: i64, nameHash: u64, values: std.json.Value };
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const ev = try std.json.parseFromSlice(struct { type: []const u8, event: []const u8, payload: Payload }, alloc, after.json, opts);
    defer ev.deinit();
    try std.testing.expectEqualStrings("trackFxParams", ev.value.event);
    try std.testing.expectEqualStrings(fx_guid, ev.value.payload.fxGuid);
    try std.testing.expectEqual(@as(i64, 0), ev.value.payload.paramCount);
    try std.testing.expectEqual(@as(usize, 0), ev.value.payload.values.object.count());

    // Its nameHash is the one getParams returns for the empty skeleton.
    const ctx = ParamNamesCtx(@TypeOf(&m)){ .api = &m, .track = track, .fx_idx = 0, .track_guid = track_guid, .fx_guid = fx_guid, .param_count = 0 };
    const skeleton = try protocol.writeAlloc(alloc, 256, ctx, writeParamNames);
    defer alloc.free(skeleton);
    const sk = try std.json.parseFromSlice(struct { nameHash: u64 }, alloc, skeleton, opts);
    defer sk.deinit();
    try std.testing.expectEqual(sk.value.nameHash, ev.value.payload.nameHash);
}

test "trackFx/getParams reads each parameter name from the plugin once" {
    const mock = @import("../reaper/mock/mod.zig");
    const alloc = std.testing.allocator;
    var m = mock.MockBackend{ .track_count = 1 };
    m.tracks[1].fx[0].setParam(0, "Freq", 0.5, "");
    m.tracks[1].fx[0].setParam(1, "Gain", 0.5, "");
    m.tracks[1].fx[0].setParam(2, "Q", 0.5, "");
    m.tracks[1].fx_count = 1;
    const track = m.getTrackByIdx(0).?;

    m.resetCalls();
    const ctx = ParamNamesCtx(@TypeOf(&m)){ .api = &m, .track = track, .fx_idx = 0, .track_guid = "{T}", .fx_guid = "{F}", .param_count = 3 };
    const skeleton = try protocol.writeAlloc(alloc, 4096, ctx, writeParamNames);
    defer alloc.free(skeleton);
    try std.testing.expectEqual(@as(usize, 3), m.getCallCount(.trackFxGetParamName));
}

test "ParamNameHasher tells apart names that concatenate alike and fits a JavaScript number" {
    var a = ParamNameHasher{};
    a.update("ab");
    a.update("c");
    var b = ParamNameHasher{};
    b.update("a");
    b.update("bc");
    var none = ParamNameHasher{};

    const ha = a.final();
    const hb = b.final();
    try std.testing.expect(ha != hb);
    try std.testing.expect(ha <= max_safe_json_integer);
    try std.testing.expect(hb <= max_safe_json_integer);
    try std.testing.expect(none.final() <= max_safe_json_integer);
}
