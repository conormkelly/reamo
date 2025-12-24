const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Region command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "region/add", .handler = handleRegionAdd },
    .{ .name = "region/update", .handler = handleRegionUpdate },
    .{ .name = "region/delete", .handler = handleRegionDelete },
    .{ .name = "region/goto", .handler = handleRegionGoto },
};

fn handleRegionAdd(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const start = cmd.getFloat("start") orelse {
        response.err("MISSING_START", "Region start is required");
        return;
    };
    const end = cmd.getFloat("end") orelse {
        response.err("MISSING_END", "Region end is required");
        return;
    };
    const color = cmd.getInt("color") orelse 0;

    var name_buf: [65]u8 = undefined;
    const name = mod.toNullTerminated(&name_buf, cmd.getString("name"));

    api.undoBeginBlock();
    const id = api.addRegion(start, end, name, color);
    api.undoEndBlock("Reamo: Add region");
    if (id >= 0) {
        api.log("Reamo: Added region {d} from {d:.2} to {d:.2}", .{ id, start, end });
    }
}

fn handleRegionUpdate(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Region id is required");
        return;
    };
    const start = cmd.getFloat("start") orelse 0;
    const end = cmd.getFloat("end") orelse 0;
    const color = cmd.getInt("color") orelse 0;

    var name_buf: [65]u8 = undefined;
    const name = mod.toNullTerminated(&name_buf, cmd.getString("name"));

    api.undoBeginBlock();
    if (api.updateRegion(id, start, end, name, color)) {
        api.log("Reamo: Updated region {d}", .{id});
    }
    api.undoEndBlock("Reamo: Update region");
}

fn handleRegionDelete(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Region id is required");
        return;
    };
    api.undoBeginBlock();
    if (api.deleteRegion(id)) {
        api.log("Reamo: Deleted region {d}", .{id});
    }
    api.undoEndBlock("Reamo: Delete region");
}

fn handleRegionGoto(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Region id is required");
        return;
    };

    // Find the region start position by enumerating
    var idx: c_int = 0;
    while (api.enumMarker(idx)) |info| : (idx += 1) {
        if (info.is_region and info.id == id) {
            api.setCursorPos(info.pos);
            return;
        }
    }

    response.err("NOT_FOUND", "Region not found");
}
