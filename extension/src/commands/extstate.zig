const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// ExtState command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "extstate/get", .handler = handleGet },
    .{ .name = "extstate/set", .handler = handleSet },
    .{ .name = "extstate/projGet", .handler = handleProjGet },
    .{ .name = "extstate/projSet", .handler = handleProjSet },
};

// Get global extended state value
fn handleGet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const section = cmd.getString("section") orelse {
        response.err("MISSING_SECTION", "section is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };

    // Convert to null-terminated strings
    var section_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    const section_z = mod.toNullTerminated(&section_buf, section);
    const key_z = mod.toNullTerminated(&key_buf, key);

    if (api.getExtStateValue(section_z, key_z)) |value| {
        // Build JSON response with escaped value
        var payload_buf: [1024]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"value\":\"{s}\"}}", .{value}) catch {
            response.err("VALUE_TOO_LONG", "Value exceeds buffer size");
            return;
        };
        response.success(payload);
    } else {
        // Return null value if not found
        response.success("{\"value\":null}");
    }
}

// Set global extended state value
fn handleSet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const section = cmd.getString("section") orelse {
        response.err("MISSING_SECTION", "section is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };
    const value = cmd.getString("value") orelse {
        response.err("MISSING_VALUE", "value is required");
        return;
    };

    // persist defaults to false
    const persist = if (cmd.getInt("persist")) |p| p != 0 else false;

    // Convert to null-terminated strings
    var section_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    var value_buf: [1025]u8 = undefined;
    const section_z = mod.toNullTerminated(&section_buf, section);
    const key_z = mod.toNullTerminated(&key_buf, key);

    // Value can be longer
    const value_len = @min(value.len, 1024);
    @memcpy(value_buf[0..value_len], value[0..value_len]);
    value_buf[value_len] = 0;
    const value_z: [*:0]const u8 = @ptrCast(&value_buf);

    api.setExtStateValue(section_z, key_z, value_z, persist);
    api.log("Reamo: Set extstate {s}/{s} (persist={any})", .{ section, key, persist });
    response.success(null);
}

// Get project-specific extended state value
fn handleProjGet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const extname = cmd.getString("extname") orelse {
        response.err("MISSING_EXTNAME", "extname is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };

    // Convert to null-terminated strings
    var extname_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    const extname_z = mod.toNullTerminated(&extname_buf, extname);
    const key_z = mod.toNullTerminated(&key_buf, key);

    var value_buf: [16384]u8 = undefined;
    if (api.getProjExtStateValue(extname_z, key_z, &value_buf)) |value| {
        // Build JSON response
        var payload_buf: [16500]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"value\":\"{s}\"}}", .{value}) catch {
            response.err("VALUE_TOO_LONG", "Value exceeds buffer size");
            return;
        };
        response.success(payload);
    } else {
        response.success("{\"value\":null}");
    }
}

// Set project-specific extended state value
fn handleProjSet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const extname = cmd.getString("extname") orelse {
        response.err("MISSING_EXTNAME", "extname is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };
    const value = cmd.getString("value") orelse {
        response.err("MISSING_VALUE", "value is required");
        return;
    };

    // Convert to null-terminated strings
    var extname_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    var value_buf: [16385]u8 = undefined;
    const extname_z = mod.toNullTerminated(&extname_buf, extname);
    const key_z = mod.toNullTerminated(&key_buf, key);

    // Value can be longer for project state
    const value_len = @min(value.len, 16384);
    @memcpy(value_buf[0..value_len], value[0..value_len]);
    value_buf[value_len] = 0;
    const value_z: [*:0]const u8 = @ptrCast(&value_buf);

    api.setProjExtStateValue(extname_z, key_z, value_z);
    api.log("Reamo: Set proj extstate {s}/{s}", .{ extname, key });
    response.success(null);
}
