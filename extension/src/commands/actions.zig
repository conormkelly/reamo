const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const ztracy = @import("ztracy");

// Get toggle state of an action (1=on, 0=off, -1=not a toggle action)
// Accepts either:
//   - commandId (int): Numeric command ID (for native REAPER actions)
//   - name (string): Named command identifier like "_SWS_SAVESEL" (for SWS/scripts)
// If both provided, name takes precedence.
pub fn handleGetToggleState(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Try named command first (for SWS/scripts)
    const command_id: c_int = if (cmd.getString("name")) |name| blk: {
        const resolved = api.namedCommandLookup(name);
        if (resolved == 0) {
            response.err("NOT_FOUND", "Named command not found");
            return;
        }
        break :blk resolved;
    } else if (cmd.getInt("commandId")) |id| blk: {
        break :blk id;
    } else {
        response.err("MISSING_PARAM", "commandId or name is required");
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

    // Optional sectionId (default: 0 = main section)
    const section_id = cmd.getInt("sectionId") orelse 0;

    // Delegate to appropriate executor based on section
    if (section_id >= 32060 and section_id <= 32062) {
        // MIDI Editor sections - requires active MIDI editor window
        const midi_hwnd = api.midiEditorGetActive();
        if (midi_hwnd == null) {
            response.err("NO_MIDI_EDITOR", "MIDI Editor not active");
            return;
        }
        _ = api.midiEditorOnCommand(midi_hwnd, command_id);
        logging.debug("Executed MIDI Editor command {d} in section {d}", .{ command_id, section_id });
    } else {
        // Main sections (0, 100, 32063) use Main_OnCommand
        api.runCommand(command_id);
        logging.debug("Executed command {d}", .{command_id});
    }
    response.success(null);
}

// Execute a REAPER action by named command identifier (e.g., "_SWS_ABOUT")
pub fn handleExecuteByName(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const name = cmd.getString("name") orelse {
        response.err("MISSING_NAME", "name is required");
        return;
    };

    // Optional sectionId (default: 0 = main section)
    const section_id = cmd.getInt("sectionId") orelse 0;

    const command_id = api.namedCommandLookup(name);
    if (command_id == 0) {
        response.err("NOT_FOUND", "Named command not found");
        return;
    }

    // Delegate to appropriate executor based on section
    if (section_id >= 32060 and section_id <= 32062) {
        // MIDI Editor sections - requires active MIDI editor window
        const midi_hwnd = api.midiEditorGetActive();
        if (midi_hwnd == null) {
            response.err("NO_MIDI_EDITOR", "MIDI Editor not active");
            return;
        }
        _ = api.midiEditorOnCommand(midi_hwnd, command_id);
        logging.debug("Executed MIDI Editor named command {s} in section {d}", .{ name, section_id });
    } else {
        // Main sections (0, 100, 32063) use Main_OnCommand
        api.runCommand(command_id);
        logging.debug("Executed named command {s}", .{name});
    }
    response.success(null);
}

// Section IDs for action enumeration
const SECTIONS = [_]c_int{ 0, 100, 32060, 32061, 32062, 32063 };

// Get all actions across all sections
// Response format: [[cmd_id, section_id, "name", is_toggle, named_id], ...]
// named_id is the stable string identifier (e.g., "_SWS_SAVESEL") or null for native actions
pub fn handleGetActions(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const zone = ztracy.ZoneN(@src(), "action/getActions");
    defer zone.End();

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
        var name_ptr: [*:0]const u8 = "";

        while (true) {
            const cmd_id = api.enumerateActions(section, idx, &name_ptr);
            if (cmd_id == 0) break;

            const is_toggle: u8 = if (api.getCommandStateEx(section_id, cmd_id) != -1) 1 else 0;
            const name = std.mem.span(name_ptr);

            // Get stable string identifier for SWS/scripts (null for native actions)
            // NOTE: ReverseNamedCommandLookup returns WITHOUT leading underscore
            const raw_named_id = api.reverseNamedCommandLookup(cmd_id);

            if (!first) {
                writer.writeAll(",") catch {
                    logging.warn("actions: buffer overflow at action {d}", .{total_count});
                    return;
                };
            }
            first = false;

            // Terse format: [cmd_id, section_id, "name", is_toggle, named_id]
            // Escape quotes in name for JSON safety
            writer.print("[{d},{d},\"", .{ cmd_id, section_id }) catch {
                logging.warn("actions: buffer overflow at action {d}", .{total_count});
                return;
            };

            protocol.writeJsonString(writer, name) catch return;

            // Write is_toggle and named_id
            writer.print("\",{d},", .{is_toggle}) catch {
                logging.warn("actions: buffer overflow at action {d}", .{total_count});
                return;
            };

            // Write named_id: "_PREFIX_NAME" or null
            // Prepend underscore since API returns without it
            if (raw_named_id) |nid| {
                writer.writeAll("\"_") catch return;
                protocol.writeJsonString(writer, nid) catch return;
                writer.writeAll("\"]") catch return;
            } else {
                writer.writeAll("null]") catch return;
            }

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
