const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "reaper_reamo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = websocket.module("websocket") },
            },
        }),
    });

    b.installArtifact(lib);

    // Unit tests - test modules that don't depend on websocket
    const test_modules = [_][]const u8{
        "src/protocol.zig",
        "src/transport.zig",
        "src/markers.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    for (test_modules) |src| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_tests.step);
    }
}
