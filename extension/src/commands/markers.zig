const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Marker command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "marker/add", .handler = handleMarkerAdd },
    .{ .name = "marker/update", .handler = handleMarkerUpdate },
    .{ .name = "marker/delete", .handler = handleMarkerDelete },
    .{ .name = "marker/goto", .handler = handleMarkerGoto },
    .{ .name = "marker/prev", .handler = handleMarkerPrev },
    .{ .name = "marker/next", .handler = handleMarkerNext },
};

fn handleMarkerAdd(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const pos = mod.validatePosition(cmd.getFloat("position")) orelse {
        response.err("INVALID_POSITION", "Position must be a non-negative number");
        return;
    };
    const color = cmd.getInt("color") orelse 0;

    var name_buf: [65]u8 = undefined;
    const name = mod.toNullTerminated(&name_buf, cmd.getString("name"));

    api.undoBeginBlock();
    const id = api.addMarker(pos, name, color);
    api.undoEndBlock("Reamo: Add marker");
    if (id >= 0) {
        api.log("Reamo: Added marker {d} at {d:.2}", .{ id, pos });
    }
}

fn handleMarkerUpdate(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Marker id is required");
        return;
    };

    // Look up current marker state for PATCH semantics
    var current_pos: f64 = 0;
    var current_name: []const u8 = "";
    var current_color: c_int = 0;
    var found = false;

    var idx: c_int = 0;
    while (api.enumMarker(idx)) |info| : (idx += 1) {
        if (!info.is_region and info.id == id) {
            current_pos = info.pos;
            current_name = info.name;
            current_color = info.color;
            found = true;
            break;
        }
    }

    if (!found) {
        response.err("NOT_FOUND", "Marker not found");
        return;
    }

    // PATCH semantics: use provided values, fall back to current
    const pos = cmd.getFloat("position") orelse current_pos;

    // Name: use provided if non-empty, else preserve current
    var name_buf: [65]u8 = undefined;
    const provided_name = cmd.getString("name");
    const name = if (provided_name) |n| blk: {
        if (n.len == 0) break :blk mod.toNullTerminated(&name_buf, current_name);
        break :blk mod.toNullTerminated(&name_buf, n);
    } else mod.toNullTerminated(&name_buf, current_name);

    // Color: null = preserve, 0 = reset to default, other = use value
    const color_provided = cmd.getInt("color");
    const color = color_provided orelse current_color;
    const reset_to_default = color_provided != null and color_provided.? == 0;

    api.undoBeginBlock();

    // Special case: color=0 explicitly means "reset to default"
    // REAPER's SetProjectMarker4 treats 0 as "don't modify color"
    // Workaround: delete and recreate marker with same ID
    if (reset_to_default) {
        _ = api.deleteMarker(id);
        _ = api.addMarkerWithId(pos, name, 0, id);
        api.log("Reamo: Reset marker {d} to default color", .{id});
    } else {
        if (api.updateMarker(id, pos, name, color)) {
            api.log("Reamo: Updated marker {d}", .{id});
        }
    }

    api.undoEndBlock("Reamo: Update marker");
}

fn handleMarkerDelete(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Marker id is required");
        return;
    };
    api.undoBeginBlock();
    if (api.deleteMarker(id)) {
        api.log("Reamo: Deleted marker {d}", .{id});
    }
    api.undoEndBlock("Reamo: Delete marker");
}

fn handleMarkerGoto(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Marker id is required");
        return;
    };

    // Find the marker position by enumerating
    var idx: c_int = 0;
    while (api.enumMarker(idx)) |info| : (idx += 1) {
        if (!info.is_region and info.id == id) {
            api.setCursorPos(info.pos);
            return;
        }
    }

    response.err("NOT_FOUND", "Marker not found");
}

// Go to previous marker (uses REAPER's built-in command)
fn handleMarkerPrev(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_PREV_MARKER);
}

// Go to next marker (uses REAPER's built-in command)
fn handleMarkerNext(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_NEXT_MARKER);
}
