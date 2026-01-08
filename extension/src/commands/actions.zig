const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// Get toggle state of an action (1=on, 0=off, -1=not a toggle action)
pub fn handleGetToggleState(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const command_id = cmd.getInt("commandId") orelse {
        response.err("MISSING_COMMAND_ID", "commandId is required");
        return;
    };

    const state = api.getCommandState(command_id);
    var payload_buf: [32]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"state\":{d}}}", .{state}) catch {
        logging.warn("actions: getToggleState response format failed", .{});
        return;
    };
    response.success(payload);
}

// Execute a REAPER action by command ID
pub fn handleExecuteCommand(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const command_id = cmd.getInt("commandId") orelse {
        response.err("MISSING_COMMAND_ID", "commandId is required");
        return;
    };

    api.runCommand(command_id);
    logging.debug("Executed command {d}", .{command_id});
    response.success(null);
}

// Execute a REAPER action by named command identifier (e.g., "_SWS_ABOUT")
pub fn handleExecuteByName(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const name = cmd.getString("name") orelse {
        response.err("MISSING_NAME", "name is required");
        return;
    };

    const command_id = api.namedCommandLookup(name);
    if (command_id == 0) {
        response.err("NOT_FOUND", "Named command not found");
        return;
    }

    api.runCommand(command_id);
    logging.debug("Executed named command {s}", .{name});
    response.success(null);
}

// Section IDs for action enumeration
const SECTIONS = [_]c_int{ 0, 100, 32060, 32061, 32062, 32063 };

// Get all actions across all sections
// Response format: [[cmd_id, section_id, "name", is_toggle], ...]
pub fn handleGetActions(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Use scratch arena for temporary allocation
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();

    // Allocate 2MB buffer for JSON output (enough for ~10000 actions)
    const buf = scratch.alloc(u8, 2 * 1024 * 1024) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };

    var stream = std.io.fixedBufferStream(buf);
    var writer = stream.writer();

    writer.writeAll("[") catch {
        logging.warn("actions: failed to write opening bracket", .{});
        return;
    };

    var first = true;
    var total_count: usize = 0;

    for (SECTIONS) |section_id| {
        const section = api.getSectionFromUniqueID(section_id) orelse continue;

        var idx: c_int = 0;
        var name_ptr: [*:0]const u8 = undefined;

        while (true) {
            const cmd_id = api.enumerateActions(section, idx, &name_ptr);
            if (cmd_id == 0) break;

            const is_toggle: u8 = if (api.getCommandStateEx(section_id, cmd_id) != -1) 1 else 0;
            const name = std.mem.span(name_ptr);

            if (!first) {
                writer.writeAll(",") catch {
                    logging.warn("actions: buffer overflow at action {d}", .{total_count});
                    return;
                };
            }
            first = false;

            // Terse format: [cmd_id, section_id, "name", is_toggle]
            // Escape quotes in name for JSON safety
            writer.print("[{d},{d},\"", .{ cmd_id, section_id }) catch {
                logging.warn("actions: buffer overflow at action {d}", .{total_count});
                return;
            };

            for (name) |c| {
                switch (c) {
                    '"' => writer.writeAll("\\\"") catch return,
                    '\\' => writer.writeAll("\\\\") catch return,
                    '\n' => writer.writeAll("\\n") catch return,
                    '\r' => writer.writeAll("\\r") catch return,
                    '\t' => writer.writeAll("\\t") catch return,
                    else => writer.writeByte(c) catch return,
                }
            }

            writer.print("\",{d}]", .{is_toggle}) catch {
                logging.warn("actions: buffer overflow at action {d}", .{total_count});
                return;
            };

            idx += 1;
            total_count += 1;
        }
    }

    writer.writeAll("]") catch {
        logging.warn("actions: failed to write closing bracket", .{});
        return;
    };

    logging.info("action/getActions: returning {d} actions, {d} bytes", .{ total_count, stream.pos });
    response.successLargePayload(stream.getWritten());
}
