const std = @import("std");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");

// Command handler function type
pub const Handler = *const fn (*const reaper.Api, protocol.CommandMessage) void;

// Command registry entry
const Entry = struct {
    name: []const u8,
    handler: Handler,
};

// Static command registry - add new commands here
const registry = [_]Entry{
    .{ .name = "transport/play", .handler = handlePlay },
    .{ .name = "transport/stop", .handler = handleStop },
    .{ .name = "transport/pause", .handler = handlePause },
    .{ .name = "transport/record", .handler = handleRecord },
    .{ .name = "transport/toggle", .handler = handleToggle },
    .{ .name = "transport/seek", .handler = handleSeek },
};

// Dispatch a command message to the appropriate handler
pub fn dispatch(api: *const reaper.Api, data: []const u8) void {
    const msg_type = protocol.MessageType.parse(data);

    switch (msg_type) {
        .command => {
            const cmd = protocol.CommandMessage.parse(data) orelse {
                api.log("Reamo: Failed to parse command", .{});
                return;
            };

            for (registry) |entry| {
                if (std.mem.eql(u8, cmd.command, entry.name)) {
                    entry.handler(api, cmd);
                    return;
                }
            }

            api.log("Reamo: Unknown command: {s}", .{cmd.command});
        },
        .unknown => {
            api.log("Reamo: Unknown message type", .{});
        },
    }
}

// Transport command handlers

fn handlePlay(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.PLAY);
}

fn handleStop(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.STOP);
}

fn handlePause(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.PAUSE);
}

fn handleRecord(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.RECORD);
}

fn handleToggle(api: *const reaper.Api, _: protocol.CommandMessage) void {
    const state = api.playState();
    if (state & 1 != 0) {
        // Currently playing, pause
        api.runCommand(reaper.Command.PAUSE);
    } else {
        // Currently stopped/paused, play
        api.runCommand(reaper.Command.PLAY);
    }
}

fn handleSeek(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    if (cmd.getFloat("position")) |pos| {
        api.setCursorPos(pos);
    }
}

// Tests
test "dispatch handles unknown commands gracefully" {
    // This test verifies the code doesn't crash on unknown commands
    // We can't easily test REAPER integration, but we can test parsing
    const data = "{\"type\":\"command\",\"command\":\"unknown/command\"}";
    const cmd = protocol.CommandMessage.parse(data);
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("unknown/command", cmd.?.command);
}

test "registry contains expected commands" {
    const expected = [_][]const u8{
        "transport/play",
        "transport/stop",
        "transport/pause",
        "transport/record",
        "transport/toggle",
        "transport/seek",
    };

    for (expected) |name| {
        var found = false;
        for (registry) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}
