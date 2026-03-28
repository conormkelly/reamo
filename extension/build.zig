const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tracy profiler option - must use ReleaseFast due to Zig 0.15 bug
    const enable_tracy = b.option(bool, "tracy", "Enable Tracy profiler") orelse false;

    const httpz = b.dependency("httpz", .{
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
                .{ .name = "httpz", .module = httpz.module("httpz") },
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

    // Dev mode: fresh HTML reads per request (no caching). Use -Ddev=true for frontend development.
    const enable_dev = b.option(bool, "dev", "Enable dev mode (fresh HTML reads per request)") orelse false;
    const dev_options = b.addOptions();
    dev_options.addOption(bool, "enable_dev", enable_dev);
    lib.root_module.addOptions("dev_options", dev_options);

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
                "-x", "c++",
            },
        });
        // SWELL modstub: provides SWELL_dllMain + doinit() which resolves all
        // SWELL function pointers at plugin load time. Required for SWELL's
        // window management (GDK) to work correctly.
        lib.addCSourceFile(.{
            .file = b.path("src/platform/swell_modstub.cpp"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
                "-fvisibility=hidden",
                "-DSWELL_PROVIDED_BY_APP",
                "-I/home/conork/Dev/reaper-sdk/WDL/swell",
            },
        });
        lib.linkLibCpp();
    } else if (target.result.os.tag == .windows) {
        // Windows: link system libraries for sockets, timers, and network detection.
        // No SWELL bridge needed — swell.zig gates all functions with comptime checks.
        lib.linkSystemLibrary("ws2_32"); // Winsock2 (httpz sockets, setsockopt)
        lib.linkSystemLibrary("kernel32"); // GetComputerNameExA (hostname)
        lib.linkSystemLibrary("user32"); // SetTimer/KillTimer (fast_timer.zig)
        lib.linkSystemLibrary("iphlpapi"); // GetAdaptersAddresses (network_detect.zig)
        lib.linkSystemLibrary("gdi32"); // GDI: CreateCompatibleDC, CreateDIBSection, BitBlt (swell.zig)
    }

    b.installArtifact(lib);

    // Unit tests - test modules that don't have parent (../) imports
    // Note: state/ modules are tested via main.zig test block (they have ../ imports)
    // Note: commands/mod.zig tests run via library build (depends on ws_server)
    const test_modules = [_][]const u8{
        "src/core/protocol.zig",
        "src/server/frame_arena.zig",
        "src/server/host_validation.zig",
        "src/audio/ring_buffer.zig",
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
    // Requires httpz, ztracy, qrcodegen, CSurf C++, and SWELL bridge
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "httpz", .module = httpz.module("httpz") },
            },
        }),
    });
    main_tests.root_module.addImport("ztracy", ztracy_dep.module("root"));
    main_tests.root_module.addOptions("csurf_options", csurf_options);
    main_tests.root_module.addOptions("dev_options", dev_options);
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
        main_tests.addCSourceFile(.{
            .file = b.path("src/platform/swell_modstub.cpp"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
                "-fvisibility=hidden",
                "-DSWELL_PROVIDED_BY_APP",
                "-I/home/conork/Dev/reaper-sdk/WDL/swell",
            },
        });
        main_tests.linkLibCpp();
    } else if (target.result.os.tag == .windows) {
        main_tests.linkSystemLibrary("ws2_32");
        main_tests.linkSystemLibrary("kernel32");
        main_tests.linkSystemLibrary("user32");
        main_tests.linkSystemLibrary("iphlpapi");
        main_tests.linkSystemLibrary("gdi32");
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
