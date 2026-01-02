const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// Region command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "region/add", .handler = handleRegionAdd },
    .{ .name = "region/update", .handler = handleRegionUpdate },
    .{ .name = "region/delete", .handler = handleRegionDelete },
    .{ .name = "region/goto", .handler = handleRegionGoto },
    .{ .name = "region/batch", .handler = handleRegionBatch },
};

pub fn handleRegionAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
        logging.debug("Added region {d} from {d:.2} to {d:.2}", .{ id, start, end });
    }
}

pub fn handleRegionUpdate(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
        logging.debug("Updated region {d}", .{id});
    }
    api.undoEndBlock("Reamo: Update region");
}

pub fn handleRegionDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const id = cmd.getInt("id") orelse {
        response.err("MISSING_ID", "Region id is required");
        return;
    };
    api.undoBeginBlock();
    if (api.deleteRegion(id)) {
        logging.debug("Deleted region {d}", .{id});
    }
    api.undoEndBlock("Reamo: Delete region");
}

pub fn handleRegionGoto(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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

// ============================================================================
// Batch operations
// ============================================================================

/// Handle batch region operations (create, update, delete)
/// Wraps all ops in a single undo block
pub fn handleRegionBatch(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Find the ops array in raw JSON
    const ops_start = std.mem.indexOf(u8, cmd.raw, "\"ops\"") orelse {
        response.err("MISSING_OPS", "ops array is required");
        return;
    };

    // Find opening bracket
    const bracket_start = std.mem.indexOfPos(u8, cmd.raw, ops_start, "[") orelse {
        response.err("INVALID_OPS", "ops must be an array");
        return;
    };

    // Find matching closing bracket
    const bracket_end = findMatchingBracket(cmd.raw, bracket_start) orelse {
        response.err("INVALID_OPS", "malformed ops array");
        return;
    };

    const ops_json = cmd.raw[bracket_start .. bracket_end + 1];

    // Track results
    var applied: u32 = 0;
    var skipped: u32 = 0;
    var warnings_buf: [512]u8 = undefined;
    var warnings_len: usize = 0;

    // Single undo block for entire batch
    api.undoBeginBlock();

    // Iterate through ops array
    var iter = JsonArrayIterator.init(ops_json);
    while (iter.next()) |op_json| {
        const result = processOp(api, op_json);
        switch (result) {
            .success => applied += 1,
            .skipped => |reason| {
                skipped += 1;
                // Append warning if there's room
                if (warnings_len + reason.len + 3 < warnings_buf.len) {
                    if (warnings_len > 0) {
                        warnings_buf[warnings_len] = ',';
                        warnings_len += 1;
                    }
                    warnings_buf[warnings_len] = '"';
                    warnings_len += 1;
                    @memcpy(warnings_buf[warnings_len..][0..reason.len], reason);
                    warnings_len += reason.len;
                    warnings_buf[warnings_len] = '"';
                    warnings_len += 1;
                }
            },
        }
    }

    api.undoEndBlock("Reamo: Batch region edit");

    // Build response
    var resp_buf: [256]u8 = undefined;
    const warnings_json = if (warnings_len > 0) warnings_buf[0..warnings_len] else "";
    const resp = std.fmt.bufPrint(&resp_buf, "{{\"applied\":{d},\"skipped\":{d},\"warnings\":[{s}]}}", .{ applied, skipped, warnings_json }) catch {
        response.success(null);
        return;
    };

    response.success(resp);
    logging.debug("Batch region edit - applied {d}, skipped {d}", .{ applied, skipped });
}

const OpResult = union(enum) {
    success: void,
    skipped: []const u8,
};

/// Process a single operation from the batch
fn processOp(api: anytype, op_json: []const u8) OpResult {
    const op_type = protocol.jsonGetString(op_json, "op") orelse {
        return .{ .skipped = "missing op type" };
    };

    if (std.mem.eql(u8, op_type, "update")) {
        return processUpdate(api, op_json);
    } else if (std.mem.eql(u8, op_type, "delete")) {
        return processDelete(api, op_json);
    } else if (std.mem.eql(u8, op_type, "create")) {
        return processCreate(api, op_json);
    } else {
        return .{ .skipped = "unknown op type" };
    }
}

/// Process an update operation
fn processUpdate(api: anytype, op_json: []const u8) OpResult {
    const id = protocol.jsonGetInt(op_json, "id") orelse {
        return .{ .skipped = "update missing id" };
    };

    // Look up current region state for PATCH semantics
    var current_start: f64 = 0;
    var current_end: f64 = 0;
    var current_name: []const u8 = "";
    var current_color: c_int = 0;
    var found = false;

    var idx: c_int = 0;
    while (api.enumMarker(idx)) |info| : (idx += 1) {
        if (info.is_region and info.id == id) {
            current_start = info.pos;
            current_end = info.end;
            current_name = info.name;
            current_color = info.color;
            found = true;
            break;
        }
    }

    if (!found) {
        return .{ .skipped = "region not found" };
    }

    // PATCH semantics: use provided values, fall back to current
    const start = protocol.jsonGetFloat(op_json, "start") orelse current_start;
    const end = protocol.jsonGetFloat(op_json, "end") orelse current_end;

    // Name: use provided if exists, else preserve current
    var name_buf: [65]u8 = undefined;
    const provided_name = protocol.jsonGetString(op_json, "name");
    const name = if (provided_name) |n|
        mod.toNullTerminated(&name_buf, n)
    else
        mod.toNullTerminated(&name_buf, current_name);

    // Color: null = preserve, 0 = reset to default, other = use value
    const color_provided = protocol.jsonGetInt(op_json, "color");
    const color = color_provided orelse current_color;
    const reset_to_default = color_provided != null and color_provided.? == 0;

    // Special case: color=0 explicitly means "reset to default"
    // REAPER's SetProjectMarker4 treats 0 as "don't modify color"
    // Workaround: delete and recreate region with same ID
    if (reset_to_default) {
        _ = api.deleteRegion(id);
        _ = api.addRegionWithId(start, end, name, 0, id);
    } else {
        _ = api.updateRegion(id, start, end, name, color);
    }

    return .success;
}

/// Process a delete operation
fn processDelete(api: anytype, op_json: []const u8) OpResult {
    const id = protocol.jsonGetInt(op_json, "id") orelse {
        return .{ .skipped = "delete missing id" };
    };

    if (api.deleteRegion(id)) {
        return .success;
    } else {
        return .{ .skipped = "region not found" };
    }
}

/// Process a create operation
fn processCreate(api: anytype, op_json: []const u8) OpResult {
    const start = protocol.jsonGetFloat(op_json, "start") orelse {
        return .{ .skipped = "create missing start" };
    };
    const end = protocol.jsonGetFloat(op_json, "end") orelse {
        return .{ .skipped = "create missing end" };
    };

    var name_buf: [65]u8 = undefined;
    const name = mod.toNullTerminated(&name_buf, protocol.jsonGetString(op_json, "name"));
    const color = protocol.jsonGetInt(op_json, "color") orelse 0;

    const id = api.addRegion(start, end, name, color);
    if (id >= 0) {
        return .success;
    } else {
        return .{ .skipped = "failed to create region" };
    }
}

// ============================================================================
// JSON array parsing helpers
// ============================================================================

/// Find the matching closing bracket for an opening bracket
fn findMatchingBracket(data: []const u8, start: usize) ?usize {
    if (start >= data.len or data[start] != '[') return null;

    var depth: i32 = 0;
    var in_string = false;
    var i = start;

    while (i < data.len) : (i += 1) {
        const c = data[i];

        if (in_string) {
            if (c == '"' and (i == 0 or data[i - 1] != '\\')) {
                in_string = false;
            }
        } else {
            switch (c) {
                '"' => in_string = true,
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
    }

    return null;
}

/// Simple iterator over JSON array elements
const JsonArrayIterator = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) JsonArrayIterator {
        // Skip opening bracket
        var pos: usize = 0;
        if (data.len > 0 and data[0] == '[') pos = 1;
        return .{ .data = data, .pos = pos };
    }

    fn next(self: *JsonArrayIterator) ?[]const u8 {
        // Skip whitespace and commas
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',') {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (self.pos >= self.data.len) return null;
        if (self.data[self.pos] == ']') return null;

        // Expect opening brace for object
        if (self.data[self.pos] != '{') return null;

        const obj_start = self.pos;
        const obj_end = findMatchingBrace(self.data, obj_start) orelse return null;

        self.pos = obj_end + 1;
        return self.data[obj_start .. obj_end + 1];
    }
};

/// Find the matching closing brace for an opening brace
fn findMatchingBrace(data: []const u8, start: usize) ?usize {
    if (start >= data.len or data[start] != '{') return null;

    var depth: i32 = 0;
    var in_string = false;
    var i = start;

    while (i < data.len) : (i += 1) {
        const c = data[i];

        if (in_string) {
            if (c == '"' and (i == 0 or data[i - 1] != '\\')) {
                in_string = false;
            }
        } else {
            switch (c) {
                '"' => in_string = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "findMatchingBracket" {
    const data = "[{\"a\":1},{\"b\":2}]";
    try std.testing.expectEqual(@as(?usize, 16), findMatchingBracket(data, 0));
}

test "findMatchingBrace" {
    const data = "{\"nested\":{\"x\":1}}";
    try std.testing.expectEqual(@as(?usize, 17), findMatchingBrace(data, 0));
}

test "JsonArrayIterator" {
    const data = "[{\"op\":\"update\"},{\"op\":\"delete\"}]";
    var iter = JsonArrayIterator.init(data);

    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expect(std.mem.indexOf(u8, first.?, "update") != null);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expect(std.mem.indexOf(u8, second.?, "delete") != null);

    const third = iter.next();
    try std.testing.expect(third == null);
}
