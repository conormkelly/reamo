const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

pub fn handleMarkerAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
        logging.debug("Added marker {d} at {d:.2}", .{ id, pos });
    }
}

pub fn handleMarkerUpdate(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
        logging.debug("Reset marker {d} to default color", .{id});
    } else {
        if (api.updateMarker(id, pos, name, color)) {
            logging.debug("Updated marker {d}", .{id});
        }
    }

    api.undoEndBlock("Reamo: Update marker");
}

pub fn handleMarkerDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Marker id is required");
        return;
    };
    api.undoBeginBlock();
    if (api.deleteMarker(id)) {
        logging.debug("Deleted marker {d}", .{id});
    }
    api.undoEndBlock("Reamo: Delete marker");
}

pub fn handleMarkerGoto(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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

/// Go to previous marker (uses REAPER's built-in command)
pub fn handleMarkerPrev(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_PREV_MARKER);
}

/// Go to next marker (uses REAPER's built-in command)
pub fn handleMarkerNext(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_NEXT_MARKER);
}
