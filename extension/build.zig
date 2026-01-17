const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tracy profiler option - must use ReleaseFast due to Zig 0.15 bug
    const enable_tracy = b.option(bool, "tracy", "Enable Tracy profiler") orelse false;

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

    // Add Tracy (ztracy provides no-op stubs when enable_ztracy=false)
    const ztracy_dep = b.dependency("ztracy", .{
        .target = target,
        .optimize = optimize,
        .enable_ztracy = enable_tracy,
    });
    lib.root_module.addImport("ztracy", ztracy_dep.module("root"));
    if (enable_tracy) {
        lib.linkLibrary(ztracy_dep.artifact("tracy"));
    }

    b.installArtifact(lib);

    // Unit tests - test modules that don't depend on websocket or parent imports
    // Note: commands/mod.zig tests run via library build (depends on ws_server)
    const test_modules = [_][]const u8{
        "src/protocol.zig",
        "src/transport.zig",
        "src/markers.zig",
        "src/items.zig",
        "src/tracks.zig",
        "src/fx.zig",
        "src/sends.zig",
        "src/frame_arena.zig",
        "src/tiered_state.zig",
        "src/peaks_cache.zig",
        "src/peaks_subscriptions.zig",
        // Note: commands/inputs.zig tests run via library build (depends on mod.zig)
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
