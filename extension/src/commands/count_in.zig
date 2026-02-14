const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");

// Toggle count-in before playback (projmetroen bit 3)
pub fn handleTogglePlayback(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.toggleCountInPlayback();
}

// Toggle count-in before recording (projmetroen bit 4)
pub fn handleToggleRecord(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.toggleCountInRecord();
}
