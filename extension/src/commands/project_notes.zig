const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const project_notes = @import("../subscriptions/project_notes.zig");
const logging = @import("../core/logging.zig");

/// Subscribe to project notes updates.
/// Returns current notes and hash.
pub fn handleSubscribe(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.notes_subs orelse {
        response.err("NOT_INITIALIZED", "Notes subscriptions not initialized");
        return;
    };

    // Subscribe client
    subs.subscribe(api, response.client_id) catch |err| {
        logging.warn("notes/subscribe failed for client {d}: {s}", .{ response.client_id, @errorName(err) });
        response.err("SUBSCRIBE_FAILED", "Failed to subscribe to notes");
        return;
    };

    // Get current notes and hash
    if (subs.getCurrentNotes(api)) |snapshot| {
        sendNotesResponse(response, snapshot.notes, snapshot.complete, snapshot.hash);
    } else {
        // No notes available (empty or API not available)
        sendNotesResponse(response, "", true, 0);
    }
}

/// Unsubscribe from project notes updates.
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.notes_subs orelse {
        response.err("NOT_INITIALIZED", "Notes subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

/// Get current project notes (without subscribing).
pub fn handleGet(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();

    // Get notes directly from REAPER (64KB - use scratch arena, not stack)
    const buf = scratch.alloc(u8, project_notes.READ_BUF_SIZE) catch {
        response.err("ALLOC_FAILED", "Failed to allocate notes buffer");
        return;
    };
    const notes = project_notes.readNotesInto(api, buf) orelse {
        // API not available
        sendNotesResponse(response, "", true, 0);
        return;
    };

    sendNotesResponse(response, notes.text, notes.complete, project_notes.computeHash(notes.text));
}

/// Set project notes. Refused while REAPER's notes are longer than a phone
/// can carry: the phone only has their beginning, and saving would replace
/// the rest with nothing.
pub fn handleSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();

    // 64KB buffers - use scratch arena, not stack
    const current_buf = scratch.alloc(u8, project_notes.READ_BUF_SIZE) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    if (project_notes.readNotesInto(api, current_buf)) |current| {
        if (!current.complete) {
            response.err("NOTES_TOO_LONG_TO_EDIT", "REAPER's notes are longer than a phone can edit (64 KB); edit them in REAPER");
            return;
        }
    }

    // Use unescaped version to properly handle \n, \t, etc. from JSON
    const unescape_buf = scratch.alloc(u8, project_notes.MAX_NOTES_SIZE) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    const notes_input = cmd.getStringUnescaped("notes", unescape_buf) orelse {
        response.err("MISSING_NOTES", "notes field is required");
        return;
    };

    // Check size limit
    if (notes_input.len > project_notes.MAX_NOTES_SIZE - 1) {
        response.err("NOTES_TOO_LONG", "Notes exceed maximum size (64KB)");
        return;
    }

    // Sanitize the input
    const sanitized_buf = scratch.alloc(u8, project_notes.MAX_NOTES_SIZE) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    const sanitized = project_notes.sanitizeNotes(notes_input, sanitized_buf) orelse {
        response.err("NOTES_TOO_LONG", "Notes exceed maximum size (64KB) once line breaks are stored as CRLF");
        return;
    };

    // Set the notes via REAPER API (this also marks project dirty)
    api.setProjectNotes(sanitized);

    // Get the updated notes and hash to confirm
    const verify_buf = scratch.alloc(u8, project_notes.READ_BUF_SIZE) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    if (project_notes.readNotesInto(api, verify_buf)) |saved| {
        sendNotesResponse(response, saved.text, saved.complete, project_notes.computeHash(saved.text));
    } else {
        // Couldn't verify, but write likely succeeded
        response.success("{\"saved\":true}");
    }
}

/// Helper to send notes response with proper JSON escaping
/// Uses protocol.writeJsonString() for consistent escaping across all modules.
/// `complete` false adds "truncated":true: `notes` is only their beginning.
fn sendNotesResponse(response: *mod.ResponseWriter, notes: []const u8, complete: bool, hash: u64) void {
    // Format hash as hex
    var hash_buf: [16]u8 = undefined;
    const hash_hex = project_notes.hashToHex(hash, &hash_buf);

    // Use scratch arena for escaped content buffer (2x for worst-case escaping + overhead)
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();
    const payload_buf = scratch.alloc(u8, project_notes.MAX_NOTES_SIZE * 2 + 100) catch {
        response.err("ALLOC_FAILED", "Failed to allocate response buffer");
        return;
    };
    var stream = std.io.fixedBufferStream(payload_buf);
    const writer = stream.writer();

    writer.writeAll("{\"notes\":\"") catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    // Use centralized escaping function
    protocol.writeJsonString(writer, notes) catch {
        response.err("JSON_ERROR", "Failed to escape notes content");
        return;
    };

    writer.print("\",\"hash\":\"{s}\"{s}}}", .{ hash_hex, if (complete) "" else ",\"truncated\":true" }) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    response.successLargePayload(stream.getWritten());
}

/// Format a projectNotesChanged event for broadcasting
pub fn formatChangedEvent(hash: u64, buf: []u8) ?[]const u8 {
    var hash_buf: [16]u8 = undefined;
    const hash_hex = project_notes.hashToHex(hash, &hash_buf);

    return std.fmt.bufPrint(buf, "{{\"type\":\"event\",\"event\":\"projectNotesChanged\",\"payload\":{{\"hash\":\"{s}\"}}}}", .{hash_hex}) catch null;
}
