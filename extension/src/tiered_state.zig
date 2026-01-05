const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_arena = @import("frame_arena.zig");
const FrameArena = frame_arena.FrameArena;
const DoubleBufferedState = frame_arena.DoubleBufferedState;

const transport = @import("transport.zig");
const tracks = @import("tracks.zig");
const project = @import("project.zig");
const markers = @import("markers.zig");
const items = @import("items.zig");
const tempomap = @import("tempomap.zig");

// =============================================================================
// Per-Tier State Types
// =============================================================================
//
// Each tier has its own state struct allocated from its own arena.
// Tiers swap independently based on their polling frequency.
//
// HIGH TIER (30Hz):  Transport, Tracks, Metering
// MEDIUM TIER (5Hz): Project, Markers, Regions, Items
// LOW TIER (1Hz):    Tempomap
// =============================================================================

/// HIGH TIER: Real-time responsive state (30Hz)
/// Transport, track structure, fader positions, metering
pub const HighTierState = struct {
    transport: transport.State = .{},
    tracks: []tracks.Track = &.{},
    metering: tracks.MeteringState = .{},

    pub fn empty() HighTierState {
        return .{};
    }
};

/// MEDIUM TIER: Session structure (5Hz)
/// Project state, markers, regions, items, FX/sends
pub const MediumTierState = struct {
    project: project.State = .{},
    markers: []markers.Marker = &.{},
    regions: []markers.Region = &.{},
    bar_offset: c_int = 0,
    items: []items.Item = &.{},
    // FX and sends for each track (indexed by track idx)
    // These persist for 6 frames (MEDIUM tier swap interval)
    // HIGH tier references these when serializing tracks
    track_fx: [][]tracks.FxSlot = &.{},
    track_sends: [][]tracks.SendSlot = &.{},

    pub fn empty() MediumTierState {
        return .{};
    }
};

/// LOW TIER: Rarely-changing state (1Hz)
/// Tempo map, project notes
pub const LowTierState = struct {
    tempomap: tempomap.State = .{},

    pub fn empty() LowTierState {
        return .{};
    }
};

// =============================================================================
// Tiered Arenas - Per-Tier Double Buffers + Scratch
// =============================================================================
//
// Each tier has its own double-buffered arena that swaps on its polling schedule.
// The scratch arena is reset every frame for transient allocations (JSON, temps).
//
// ┌─────────────────────────────────────────────────────────┐
// │  HIGH      ┌───────┐ ┌───────┐   swap every frame      │
// │            │ cur   │ │ prev  │                         │
// │            └───────┘ └───────┘                         │
// ├─────────────────────────────────────────────────────────┤
// │  MEDIUM    ┌───────┐ ┌───────┐   swap every 6 frames   │
// │            │ cur   │ │ prev  │                         │
// │            └───────┘ └───────┘                         │
// ├─────────────────────────────────────────────────────────┤
// │  LOW       ┌───────┐ ┌───────┐   swap every 30 frames  │
// │            │ cur   │ │ prev  │                         │
// │            └───────┘ └───────┘                         │
// ├─────────────────────────────────────────────────────────┤
// │  SCRATCH   ┌─────────────────┐   reset every frame     │
// │            │  json, temps    │                         │
// │            └─────────────────┘                         │
// └─────────────────────────────────────────────────────────┘
// =============================================================================

/// Arena sizes for each tier (generous padding over expected usage)
pub const ArenaSizes = struct {
    /// HIGH tier: transport (~128B) + tracks (256 * ~500B) + metering (~1KB) ≈ 130KB
    /// With 4x headroom: 512KB per buffer
    pub const HIGH: usize = 512 * 1024;

    /// MEDIUM tier: project (~256B) + markers (1024 * 160B) + regions (1024 * 200B)
    ///              + items (4096 * 150B) ≈ 1MB
    /// With 4x headroom: 4MB per buffer
    pub const MEDIUM: usize = 4 * 1024 * 1024;

    /// LOW tier: tempomap (512 * ~32B) ≈ 16KB
    /// With 4x headroom: 64KB per buffer
    pub const LOW: usize = 64 * 1024;

    /// SCRATCH: JSON serialization buffers, temp strings
    /// Current StaticBuffers total ~100KB, with 4x headroom: 512KB
    pub const SCRATCH: usize = 512 * 1024;
};

pub const TieredArenas = struct {
    high: DoubleBufferedState(HighTierState),
    medium: DoubleBufferedState(MediumTierState),
    low: DoubleBufferedState(LowTierState),
    scratch: FrameArena,

    const Self = @This();

    /// Initialize all tiered arenas
    pub fn init(backing: Allocator) !Self {
        var self: Self = undefined;

        // Initialize HIGH tier
        self.high = try DoubleBufferedState(HighTierState).init(backing, ArenaSizes.HIGH);
        errdefer self.high.deinit(backing);

        // Initialize MEDIUM tier
        self.medium = try DoubleBufferedState(MediumTierState).init(backing, ArenaSizes.MEDIUM);
        errdefer self.medium.deinit(backing);

        // Initialize LOW tier
        self.low = try DoubleBufferedState(LowTierState).init(backing, ArenaSizes.LOW);
        errdefer self.low.deinit(backing);

        // Initialize SCRATCH arena
        self.scratch = try FrameArena.init(backing, ArenaSizes.SCRATCH);

        return self;
    }

    /// Clean up all arenas
    pub fn deinit(self: *Self, backing: Allocator) void {
        self.high.deinit(backing);
        self.medium.deinit(backing);
        self.low.deinit(backing);
        self.scratch.deinit(backing);
        self.* = undefined;
    }

    /// Begin a new frame. Always resets scratch, swaps tiers based on frame counter.
    /// Call this at the START of each frame.
    pub fn beginFrame(self: *Self, frame_counter: u32) !void {
        // Always reset scratch - used for JSON, temps every frame
        self.scratch.reset();

        // HIGH tier swaps every frame
        try self.high.beginFrame();

        // MEDIUM tier swaps every 6 frames (5Hz)
        if (frame_counter % 6 == 0) {
            try self.medium.beginFrame();
        }

        // LOW tier swaps every 30 frames (1Hz)
        if (frame_counter % 30 == 0) {
            try self.low.beginFrame();
        }
    }

    /// Get scratch allocator for transient allocations (JSON, temp strings)
    pub fn scratchAllocator(self: *Self) Allocator {
        return self.scratch.allocator();
    }

    /// Get diagnostic usage for all arenas
    pub fn usage(self: *const Self) DiagnosticUsage {
        const high_usage = self.high.usage();
        const medium_usage = self.medium.usage();
        const low_usage = self.low.usage();
        const scratch_usage = self.scratch.usage();

        return .{
            .high_used = high_usage.current_used,
            .high_capacity = high_usage.capacity,
            .high_peak = high_usage.peak_usage,
            .medium_used = medium_usage.current_used,
            .medium_capacity = medium_usage.capacity,
            .medium_peak = medium_usage.peak_usage,
            .low_used = low_usage.current_used,
            .low_capacity = low_usage.capacity,
            .low_peak = low_usage.peak_usage,
            .scratch_used = scratch_usage.used,
            .scratch_capacity = scratch_usage.capacity,
            .frame_count = high_usage.frame_count,
        };
    }

    pub const DiagnosticUsage = struct {
        high_used: usize,
        high_capacity: usize,
        high_peak: usize,
        medium_used: usize,
        medium_capacity: usize,
        medium_peak: usize,
        low_used: usize,
        low_capacity: usize,
        low_peak: usize,
        scratch_used: usize,
        scratch_capacity: usize,
        frame_count: u64,

        /// Total memory allocated across all arenas (both buffers each)
        pub fn totalAllocated(self: DiagnosticUsage) usize {
            return (self.high_capacity * 2) +
                (self.medium_capacity * 2) +
                (self.low_capacity * 2) +
                self.scratch_capacity;
        }

        /// Format usage for logging
        pub fn format(self: DiagnosticUsage, buf: []u8) ?[]const u8 {
            return std.fmt.bufPrint(buf,
                \\HIGH: {d}KB/{d}KB (peak {d}KB)
                \\MEDIUM: {d}KB/{d}KB (peak {d}KB)
                \\LOW: {d}KB/{d}KB (peak {d}KB)
                \\SCRATCH: {d}KB/{d}KB
                \\Total: {d}MB
            , .{
                self.high_used / 1024,
                self.high_capacity / 1024,
                self.high_peak / 1024,
                self.medium_used / 1024,
                self.medium_capacity / 1024,
                self.medium_peak / 1024,
                self.low_used / 1024,
                self.low_capacity / 1024,
                self.low_peak / 1024,
                self.scratch_used / 1024,
                self.scratch_capacity / 1024,
                self.totalAllocated() / (1024 * 1024),
            }) catch null;
        }
    };
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "HighTierState empty" {
    const state = HighTierState.empty();
    try testing.expectEqual(@as(usize, 0), state.tracks.len);
}

test "MediumTierState empty" {
    const state = MediumTierState.empty();
    try testing.expectEqual(@as(usize, 0), state.markers.len);
    try testing.expectEqual(@as(usize, 0), state.regions.len);
    try testing.expectEqual(@as(usize, 0), state.items.len);
}

test "LowTierState empty" {
    const state = LowTierState.empty();
    _ = state; // Just verify it compiles
}

test "TieredArenas initialization" {
    var arenas = try TieredArenas.init(testing.allocator);
    defer arenas.deinit(testing.allocator);

    // Verify all tiers accessible
    _ = arenas.high.currentState();
    _ = arenas.medium.currentState();
    _ = arenas.low.currentState();
    _ = arenas.scratchAllocator();
}

test "TieredArenas frame progression" {
    var arenas = try TieredArenas.init(testing.allocator);
    defer arenas.deinit(testing.allocator);

    // Frame 0: all tiers swap
    try arenas.beginFrame(0);
    try testing.expectEqual(@as(u64, 1), arenas.high.usage().frame_count);
    try testing.expectEqual(@as(u64, 1), arenas.medium.usage().frame_count);
    try testing.expectEqual(@as(u64, 1), arenas.low.usage().frame_count);

    // Frames 1-5: only HIGH swaps
    for (1..6) |frame| {
        try arenas.beginFrame(@intCast(frame));
    }
    try testing.expectEqual(@as(u64, 6), arenas.high.usage().frame_count);
    try testing.expectEqual(@as(u64, 1), arenas.medium.usage().frame_count);
    try testing.expectEqual(@as(u64, 1), arenas.low.usage().frame_count);

    // Frame 6: HIGH and MEDIUM swap
    try arenas.beginFrame(6);
    try testing.expectEqual(@as(u64, 7), arenas.high.usage().frame_count);
    try testing.expectEqual(@as(u64, 2), arenas.medium.usage().frame_count);
    try testing.expectEqual(@as(u64, 1), arenas.low.usage().frame_count);

    // Continue to frame 30: all tiers swap again
    for (7..30) |frame| {
        try arenas.beginFrame(@intCast(frame));
    }
    try arenas.beginFrame(30);
    try testing.expectEqual(@as(u64, 31), arenas.high.usage().frame_count);
    try testing.expectEqual(@as(u64, 6), arenas.medium.usage().frame_count); // 0, 6, 12, 18, 24, 30
    try testing.expectEqual(@as(u64, 2), arenas.low.usage().frame_count); // 0, 30
}

test "TieredArenas scratch reset every frame" {
    var arenas = try TieredArenas.init(testing.allocator);
    defer arenas.deinit(testing.allocator);

    // Allocate from scratch
    const alloc = arenas.scratchAllocator();
    _ = try alloc.alloc(u8, 1000);

    // Verify usage
    const usage1 = arenas.scratch.usage();
    try testing.expect(usage1.used >= 1000);

    // Begin frame resets scratch
    try arenas.beginFrame(1);

    const usage2 = arenas.scratch.usage();
    // Note: HIGH tier also allocated its state struct, so not exactly 0
    // but scratch should be minimal
    try testing.expect(usage2.used < 100);
}

test "TieredArenas double buffer preserves previous state" {
    var arenas = try TieredArenas.init(testing.allocator);
    defer arenas.deinit(testing.allocator);

    // Set value in frame 0
    try arenas.beginFrame(0);
    arenas.high.currentState().transport.bpm = 120.0;

    // Begin frame 1
    try arenas.beginFrame(1);

    // Previous should have our value
    try testing.expectEqual(@as(f64, 120.0), arenas.high.previousState().transport.bpm);

    // Current should be empty
    try testing.expectEqual(@as(f64, 0.0), arenas.high.currentState().transport.bpm);
}

test "TieredArenas usage diagnostics" {
    var arenas = try TieredArenas.init(testing.allocator);
    defer arenas.deinit(testing.allocator);

    const usage = arenas.usage();

    // Verify capacities match expected sizes
    try testing.expectEqual(ArenaSizes.HIGH, usage.high_capacity);
    try testing.expectEqual(ArenaSizes.MEDIUM, usage.medium_capacity);
    try testing.expectEqual(ArenaSizes.LOW, usage.low_capacity);
    try testing.expectEqual(ArenaSizes.SCRATCH, usage.scratch_capacity);

    // Total should be 2 * each tier + 1 * scratch
    const expected_total = (ArenaSizes.HIGH * 2) +
        (ArenaSizes.MEDIUM * 2) +
        (ArenaSizes.LOW * 2) +
        ArenaSizes.SCRATCH;
    try testing.expectEqual(expected_total, usage.totalAllocated());
}
