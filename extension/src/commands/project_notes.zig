const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const project_notes = @import("../project_notes.zig");

// Project notes command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "projectNotes/subscribe", .handler = handleSubscribe },
    .{ .name = "projectNotes/unsubscribe", .handler = handleUnsubscribe },
    .{ .name = "projectNotes/get", .handler = handleGet },
    .{ .name = "projectNotes/set", .handler = handleSet },
};

// Global notes subscriptions state (initialized by main.zig)
pub var g_notes_subs: ?*project_notes.NotesSubscriptions = null;

/// Subscribe to project notes updates.
/// Returns current notes and hash.
fn handleSubscribe(api: *const reaper.Api, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = g_notes_subs orelse {
        response.err("NOT_INITIALIZED", "Notes subscriptions not initialized");
        return;
    };

    // Subscribe client
    subs.subscribe(response.client_id) catch {
        response.err("SUBSCRIBE_FAILED", "Failed to subscribe to notes");
        return;
    };

    // Get current notes and hash
    if (subs.getCurrentNotes(api)) |snapshot| {
        sendNotesResponse(response, snapshot.notes, snapshot.hash);
    } else {
        // No notes available (empty or API not available)
        sendNotesResponse(response, "", 0);
    }
}

/// Unsubscribe from project notes updates.
fn handleUnsubscribe(_: *const reaper.Api, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = g_notes_subs orelse {
        response.err("NOT_INITIALIZED", "Notes subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

/// Get current project notes (without subscribing).
fn handleGet(api: *const reaper.Api, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Get notes directly from REAPER
    var buf: [project_notes.MAX_NOTES_SIZE]u8 = undefined;
    const notes = api.getProjectNotes(&buf) orelse {
        // API not available
        sendNotesResponse(response, "", 0);
        return;
    };

    const hash = project_notes.computeHash(notes);
    sendNotesResponse(response, notes, hash);
}

/// Set project notes.
fn handleSet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Use unescaped version to properly handle \n, \t, etc. from JSON
    var unescape_buf: [project_notes.MAX_NOTES_SIZE]u8 = undefined;
    const notes_input = cmd.getStringUnescaped("notes", &unescape_buf) orelse {
        response.err("MISSING_NOTES", "notes field is required");
        return;
    };

    // Check size limit
    if (notes_input.len > project_notes.MAX_NOTES_SIZE - 1) {
        response.err("NOTES_TOO_LONG", "Notes exceed maximum size (64KB)");
        return;
    }

    // Sanitize the input
    var sanitized_buf: [project_notes.MAX_NOTES_SIZE]u8 = undefined;
    const sanitized = project_notes.sanitizeNotes(notes_input, &sanitized_buf);

    // Set the notes via REAPER API (this also marks project dirty)
    api.setProjectNotes(sanitized);

    // Get the updated notes and hash to confirm
    var verify_buf: [project_notes.MAX_NOTES_SIZE]u8 = undefined;
    if (api.getProjectNotes(&verify_buf)) |saved_notes| {
        const new_hash = project_notes.computeHash(saved_notes);

        // Update subscription cache if available
        if (g_notes_subs) |subs| {
            _ = subs.getCurrentNotes(api);
        }

        sendNotesResponse(response, saved_notes, new_hash);
    } else {
        // Couldn't verify, but write likely succeeded
        response.success("{\"saved\":true}");
    }
}

/// Helper to send notes response with proper JSON escaping
fn sendNotesResponse(response: *mod.ResponseWriter, notes: []const u8, hash: u64) void {
    // Format hash as hex
    var hash_buf: [16]u8 = undefined;
    const hash_hex = project_notes.hashToHex(hash, &hash_buf);

    // We need to JSON-escape the notes content
    // Use a large buffer for escaped content
    var payload_buf: [project_notes.MAX_NOTES_SIZE * 2 + 100]u8 = undefined;
    var stream = std.io.fixedBufferStream(&payload_buf);
    var writer = stream.writer();

    writer.writeAll("{\"notes\":\"") catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    // Write JSON-escaped notes
    for (notes) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch {},
            '\\' => writer.writeAll("\\\\") catch {},
            '\n' => writer.writeAll("\\n") catch {},
            '\r' => writer.writeAll("\\r") catch {},
            '\t' => writer.writeAll("\\t") catch {},
            else => {
                if (c < 0x20) {
                    // Control character - use \u escape
                    writer.print("\\u{x:0>4}", .{c}) catch {};
                } else {
                    writer.writeByte(c) catch {};
                }
            },
        }
    }

    writer.print("\",\"hash\":\"{s}\"}}", .{hash_hex}) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    response.success(stream.getWritten());
}

/// Format a projectNotesChanged event for broadcasting
pub fn formatChangedEvent(hash: u64, buf: []u8) ?[]const u8 {
    var hash_buf: [16]u8 = undefined;
    const hash_hex = project_notes.hashToHex(hash, &hash_buf);

    return std.fmt.bufPrint(buf, "{{\"type\":\"event\",\"event\":\"projectNotesChanged\",\"payload\":{{\"hash\":\"{s}\"}}}}", .{hash_hex}) catch null;
}
