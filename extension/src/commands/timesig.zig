const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// Time signature command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "timesig/set", .handler = handleSet },
};

// Set time signature (numerator/denominator)
fn handleSet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const numerator = cmd.getInt("numerator") orelse {
        response.err("MISSING_NUMERATOR", "numerator is required");
        return;
    };

    const denominator = cmd.getInt("denominator") orelse {
        response.err("MISSING_DENOMINATOR", "denominator is required");
        return;
    };

    // Validate numerator (1-32)
    if (numerator < 1 or numerator > 32) {
        response.err("INVALID_NUMERATOR", "numerator must be between 1 and 32");
        return;
    }

    // Validate denominator (2, 4, 8, 16)
    if (denominator != 2 and denominator != 4 and denominator != 8 and denominator != 16) {
        response.err("INVALID_DENOMINATOR", "denominator must be 2, 4, 8, or 16");
        return;
    }

    // Begin undo block
    api.undoBeginBlock();

    const success = api.setTimeSignature(numerator, denominator);

    // End undo block
    api.undoEndBlock("Reamo: Adjust time signature");

    if (success) {
        logging.debug("Set time signature to {d}/{d}", .{ numerator, denominator });
        response.success(null);
    } else {
        response.err("FAILED", "Failed to set time signature");
    }
}

test "handlers registered" {
    try std.testing.expectEqual(@as(usize, 1), handlers.len);
    try std.testing.expectEqualStrings("timesig/set", handlers[0].name);
}
