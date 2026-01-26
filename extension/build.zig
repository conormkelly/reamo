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

    // CSurf integration - push-based callbacks from REAPER for instant state change notifications.
    // Enabled by default. Use -Dcsurf=false to disable for debugging.
    const enable_csurf = b.option(bool, "csurf", "Enable CSurf push-based callbacks") orelse true;

    // Pass csurf option to Zig code for conditional compilation
    const csurf_options = b.addOptions();
    csurf_options.addOption(bool, "enable_csurf", enable_csurf);
    lib.root_module.addOptions("csurf_options", csurf_options);

    if (enable_csurf) {
        // Compile C++ shim for IReaperControlSurface
        lib.addCSourceFile(.{
            .file = b.path("src/reaper/zig_control_surface.cpp"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions", // REAPER SDK doesn't use exceptions
                "-fno-rtti", // No RTTI needed
            },
        });
        // Link C++ standard library
        lib.linkLibCpp();
    }

    // QR code generation library (all platforms)
    lib.addCSourceFile(.{
        .file = b.path("lib/qrcodegen/qrcodegen.c"),
        .flags = &.{"-std=c99"},
    });
    lib.root_module.addIncludePath(b.path("lib/qrcodegen"));

    // SWELL bridge for native window support (macOS/Linux only)
    // On Windows, swell.zig uses native Win32 APIs directly
    if (target.result.os.tag == .macos) {
        lib.addCSourceFile(.{
            .file = b.path("src/platform/zig_swell_bridge.mm"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
            },
        });
        lib.linkFramework("Cocoa");
    } else if (target.result.os.tag == .linux) {
        lib.addCSourceFile(.{
            .file = b.path("src/platform/zig_swell_bridge.mm"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
                "-x", "c++", // Compile as C++ on Linux (no ObjC)
            },
        });
    }

    b.installArtifact(lib);

    // Unit tests - test modules that don't have parent (../) imports
    // Note: state/ modules are tested via main.zig test block (they have ../ imports)
    // Note: commands/mod.zig tests run via library build (depends on ws_server)
    const test_modules = [_][]const u8{
        "src/core/protocol.zig",
        "src/server/frame_arena.zig",
        // State/subscription modules with ../ imports are tested via main.zig test block
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

    // Main module tests - pulls in tests from all submodules via test block
    // Requires websocket, ztracy, qrcodegen, CSurf C++, and SWELL bridge
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = websocket.module("websocket") },
            },
        }),
    });
    main_tests.root_module.addImport("ztracy", ztracy_dep.module("root"));
    main_tests.root_module.addOptions("csurf_options", csurf_options);
    // QR code generation library (required by platform/qr_render.zig)
    main_tests.addCSourceFile(.{
        .file = b.path("lib/qrcodegen/qrcodegen.c"),
        .flags = &.{"-std=c99"},
    });
    main_tests.root_module.addIncludePath(b.path("lib/qrcodegen"));
    // CSurf C++ shim (required by server/csurf.zig)
    if (enable_csurf) {
        main_tests.addCSourceFile(.{
            .file = b.path("src/reaper/zig_control_surface.cpp"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
            },
        });
        main_tests.linkLibCpp();
    }
    // SWELL bridge (required by platform/swell.zig on macOS/Linux)
    if (target.result.os.tag == .macos) {
        main_tests.addCSourceFile(.{
            .file = b.path("src/platform/zig_swell_bridge.mm"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
            },
        });
        main_tests.linkFramework("Cocoa");
    } else if (target.result.os.tag == .linux) {
        main_tests.addCSourceFile(.{
            .file = b.path("src/platform/zig_swell_bridge.mm"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
                "-x", "c++",
            },
        });
    }
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // QR render tests - need qrcodegen C library linked
    const qr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/qr_render.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    qr_tests.addCSourceFile(.{
        .file = b.path("lib/qrcodegen/qrcodegen.c"),
        .flags = &.{"-std=c99"},
    });
    qr_tests.root_module.addIncludePath(b.path("lib/qrcodegen"));
    const run_qr_tests = b.addRunArtifact(qr_tests);
    test_step.dependOn(&run_qr_tests.step);
}
