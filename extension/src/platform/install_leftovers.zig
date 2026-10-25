//! Files the installer leaves in UserPlugins when it updates REAmo while
//! REAPER is running (see installer/Install_REAmo.lua): on Windows a loaded
//! DLL can't be replaced, only moved aside as old_reaper_reamo.<time>.dll,
//! and a failed install can leave its temporary copy. At the next start
//! nothing has them loaded, so REAmo deletes them.

const std = @import("std");
const logging = @import("../core/logging.zig");

/// Prefix of a binary moved aside by an update. Not reaper_*, so REAPER
/// never loads it.
pub const OLD_PREFIX = "old_reaper_reamo";
/// The installer's temporary copy of the new binary.
pub const TEMP_NAME = "reamo_install.tmp";

fn isLeftover(name: []const u8) bool {
    return std.mem.startsWith(u8, name, OLD_PREFIX) or std.mem.eql(u8, name, TEMP_NAME);
}

/// Delete installer leftovers from `{resource_path}/UserPlugins`. Returns how
/// many were deleted; one that can't be (another REAPER instance has it
/// loaded) is left for a later start.
pub fn remove(resource_path: []const u8) usize {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const plugins = std.fmt.bufPrint(&path_buf, "{s}/UserPlugins", .{resource_path}) catch return 0;
    var dir = std.fs.cwd().openDir(plugins, .{ .iterate = true }) catch return 0;
    defer dir.close();
    return removeIn(dir);
}

fn removeIn(dir: std.fs.Dir) usize {
    // Names first: deleting while iterating can skip entries.
    var names: [16][std.fs.max_name_bytes]u8 = undefined;
    var lens: [16]usize = undefined;
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file or !isLeftover(entry.name)) continue;
        if (count == names.len or entry.name.len > names[0].len) continue;
        @memcpy(names[count][0..entry.name.len], entry.name);
        lens[count] = entry.name.len;
        count += 1;
    }
    var removed: usize = 0;
    for (0..count) |i| {
        const name = names[i][0..lens[i]];
        if (dir.deleteFile(name)) {
            removed += 1;
            logging.info("Removed {s}, left by an update", .{name});
        } else |err| {
            logging.warn("Couldn't remove {s}, left by an update: {s}", .{ name, @errorName(err) });
        }
    }
    return removed;
}

test "removes binaries an update moved aside, and nothing of anyone else's" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{
        "old_reaper_reamo.1761400000.dll",
        "old_reaper_reamo.1761400000-1.dll",
        "reamo_install.tmp",
        "reaper_reamo.dll",
        "reaper_sws-x64.dll",
        "old_reaper_sws.dll",
    }) |name| {
        try tmp.dir.writeFile(.{ .sub_path = name, .data = "x" });
    }
    try std.testing.expectEqual(@as(usize, 3), removeIn(tmp.dir));
    try tmp.dir.access("reaper_reamo.dll", .{});
    try tmp.dir.access("reaper_sws-x64.dll", .{});
    try tmp.dir.access("old_reaper_sws.dll", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("reamo_install.tmp", .{}));
}
