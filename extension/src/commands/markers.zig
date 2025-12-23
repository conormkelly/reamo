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
    api.undoEndBlock("Add marker (Reamo)");
    if (id >= 0) {
        api.log("Reamo: Added marker {d} at {d:.2}", .{ id, pos });
    }
}

fn handleMarkerUpdate(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Marker id is required");
        return;
    };
    const pos = cmd.getFloat("position") orelse 0;
    const color = cmd.getInt("color") orelse 0;

    var name_buf: [65]u8 = undefined;
    const name = mod.toNullTerminated(&name_buf, cmd.getString("name"));

    api.undoBeginBlock();
    if (api.updateMarker(id, pos, name, color)) {
        api.log("Reamo: Updated marker {d}", .{id});
    }
    api.undoEndBlock("Update marker (Reamo)");
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
    api.undoEndBlock("Delete marker (Reamo)");
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
