const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const ztracy = @import("ztracy");

/// Get all installed FX plugins.
/// Response format: [["name", "ident"], ...]
/// - name: Display name (e.g., "Pro-Q 3")
/// - ident: Identifier for TrackFX_AddByName (e.g., "VST3: Pro-Q 3 (FabFilter)")
pub fn handleGetList(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const zone = ztracy.ZoneN(@src(), "fxPlugin/getList");
    defer zone.End();

    // Use scratch arena for temporary allocation
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();

    // Allocate 2MB buffer for JSON output (enough for ~5000 plugins)
    const buf = scratch.alloc(u8, 2 * 1024 * 1024) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };

    var stream = std.io.fixedBufferStream(buf);
    var writer = stream.writer();

    writer.writeAll("[") catch {
        logging.warn("fxPlugin/getList: failed to write opening bracket", .{});
        return;
    };

    var idx: c_int = 0;
    var first = true;
    var name_ptr: [*:0]const u8 = "";
    var ident_ptr: [*:0]const u8 = "";

    while (api.enumInstalledFX(idx, &name_ptr, &ident_ptr)) {
        if (!first) {
            writer.writeAll(",") catch {
                logging.warn("fxPlugin/getList: buffer overflow at plugin {d}", .{idx});
                return;
            };
        }
        first = false;

        const name = std.mem.span(name_ptr);
        const ident = std.mem.span(ident_ptr);

        // Write ["name","ident"]
        writer.writeAll("[\"") catch {
            logging.warn("fxPlugin/getList: buffer overflow at plugin {d}", .{idx});
            return;
        };

        writeEscapedString(&writer, name) catch {
            logging.warn("fxPlugin/getList: buffer overflow writing name at plugin {d}", .{idx});
            return;
        };

        writer.writeAll("\",\"") catch {
            logging.warn("fxPlugin/getList: buffer overflow at plugin {d}", .{idx});
            return;
        };

        writeEscapedString(&writer, ident) catch {
            logging.warn("fxPlugin/getList: buffer overflow writing ident at plugin {d}", .{idx});
            return;
        };

        writer.writeAll("\"]") catch {
            logging.warn("fxPlugin/getList: buffer overflow at plugin {d}", .{idx});
            return;
        };

        idx += 1;
    }

    writer.writeAll("]") catch {
        logging.warn("fxPlugin/getList: failed to write closing bracket", .{});
        return;
    };

    logging.info("fxPlugin/getList: returning {d} plugins, {d} bytes", .{ idx, stream.pos });
    response.successLargePayload(stream.getWritten());
}

fn writeEscapedString(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
