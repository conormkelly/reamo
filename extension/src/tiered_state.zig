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
const fx = @import("fx.zig");
const sends = @import("sends.zig");

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
    // Flat FX/sends arrays - each slot has a track_idx parent reference
    // Polled at 5Hz, broadcast as fx_state and sends_state events
    fx_slots: []fx.FxSlot = &.{},
    send_slots: []sends.SendSlot = &.{},

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

// =============================================================================
// Arena Sizing Constants and Calculation
// =============================================================================
//
// Arena sizes are calculated dynamically based on project entity counts.
// This enables support for any project size while keeping memory proportional.
//
// Key parameters:
// - MINIMUM_TOTAL: 20 MB floor for small projects
// - MAXIMUM_TOTAL: 200 MB ceiling for extreme projects
// - HEADROOM_MULTIPLIER: 2x calculated size for growth during session
// =============================================================================

/// Memory bounds for total arena allocation
pub const MemoryBounds = struct {
    /// Minimum total allocation (20 MB) - covers typical projects
    pub const MINIMUM_TOTAL: usize = 20 * 1024 * 1024;
    /// Maximum total allocation (200 MB) - absolute ceiling
    pub const MAXIMUM_TOTAL: usize = 200 * 1024 * 1024;
    /// Headroom multiplier for growth during session
    pub const HEADROOM_MULTIPLIER: usize = 2;
};

/// Per-entity byte sizes for memory calculation
/// These are based on actual struct sizes from the flattened data model
pub const EntitySizes = struct {
    pub const TRACK: usize = 150; // Track struct (flattened, no fx/sends)
    pub const TRACK_METER: usize = 21; // TrackMeter struct
    pub const ITEM: usize = 700; // Item struct (sparse, no notes/takes)
    pub const MARKER: usize = 172; // Marker struct
    pub const REGION: usize = 228; // Region struct
    pub const FX_SLOT: usize = 281; // FxSlot struct
    pub const SEND_SLOT: usize = 157; // SendSlot struct
    pub const TEMPO_EVENT: usize = 32; // TempoEvent struct
};

/// Default arena sizes (fallback when no API available, e.g. tests)
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

    /// SCRATCH: All JSON serialization (tracks, items, skeleton, metering, toggles, errors)
    /// Also used for action enumeration (~300KB for ~10000 actions)
    /// Dynamic sizing scales with project size; 2.5MB handles action lists + large projects
    pub const SCRATCH: usize = 2560 * 1024;
};

/// Entity counts from a REAPER project, used to calculate arena sizes
pub const EntityCounts = struct {
    tracks: usize = 0,
    items: usize = 0,
    markers: usize = 0,
    regions: usize = 0,
    fx_total: usize = 0,
    sends_total: usize = 0,
    tempo_events: usize = 0,

    /// Count entities from the REAPER API
    /// Pass any backend type (RealBackend, MockBackend) via anytype
    pub fn countFromApi(api: anytype) EntityCounts {
        var counts = EntityCounts{};

        // Count tracks (excluding master for this purpose, but including it for memory)
        const track_count_raw = api.trackCount();
        counts.tracks = if (track_count_raw >= 0) @intCast(track_count_raw) else 0;
        counts.tracks += 1; // Add master track

        // Iterate tracks to count FX, sends, and items
        var track_idx: c_int = 0;
        while (track_idx < track_count_raw + 1) : (track_idx += 1) {
            const track = api.getTrackByUnifiedIdx(track_idx) orelse continue;

            // Count FX
            const fx_count_raw = api.trackFxCount(track);
            if (fx_count_raw > 0) {
                counts.fx_total += @intCast(fx_count_raw);
            }

            // Count sends
            const send_count_raw = api.trackSendCount(track);
            if (send_count_raw > 0) {
                counts.sends_total += @intCast(send_count_raw);
            }

            // Count items on this track
            const item_count_raw = api.trackItemCount(track);
            if (item_count_raw > 0) {
                counts.items += @intCast(item_count_raw);
            }
        }

        // Count markers and regions via enumeration
        // markerCount returns count of marker points, not total entries
        // We need to enumerate to get actual counts
        var marker_count: usize = 0;
        var region_count: usize = 0;
        var enum_idx: c_int = 0;
        while (true) {
            const info = api.enumMarker(enum_idx) orelse break;
            if (info.is_region) {
                region_count += 1;
            } else {
                marker_count += 1;
            }
            enum_idx += 1;
        }
        counts.markers = marker_count;
        counts.regions = region_count;

        // Count tempo markers
        const tempo_count_raw = api.tempoMarkerCount();
        if (tempo_count_raw > 0) {
            counts.tempo_events = @intCast(tempo_count_raw);
        }

        return counts;
    }

    /// Format counts for logging
    pub fn format(self: EntityCounts, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "tracks={d} items={d} markers={d} regions={d} fx={d} sends={d} tempo={d}", .{
            self.tracks,
            self.items,
            self.markers,
            self.regions,
            self.fx_total,
            self.sends_total,
            self.tempo_events,
        }) catch null;
    }
};

/// Calculated arena sizes based on entity counts
pub const CalculatedSizes = struct {
    high: usize,
    medium: usize,
    low: usize,
    scratch: usize,

    /// Total memory for all arenas (each tier is double-buffered except scratch)
    pub fn totalAllocated(self: CalculatedSizes) usize {
        return (self.high * 2) + (self.medium * 2) + (self.low * 2) + self.scratch;
    }

    /// Calculate arena sizes from entity counts
    /// Applies 2x headroom, 20 MB floor, 200 MB ceiling
    pub fn fromCounts(counts: EntityCounts) CalculatedSizes {
        // Calculate raw sizes per tier
        // HIGH: tracks + metering
        const high_raw = (counts.tracks * (EntitySizes.TRACK + EntitySizes.TRACK_METER)) +
            1024; // Transport state overhead

        // MEDIUM: items + markers + regions + fx + sends + project state
        const medium_raw = (counts.items * EntitySizes.ITEM) +
            (counts.markers * EntitySizes.MARKER) +
            (counts.regions * EntitySizes.REGION) +
            (counts.fx_total * EntitySizes.FX_SLOT) +
            (counts.sends_total * EntitySizes.SEND_SLOT) +
            4096; // Project state overhead

        // LOW: tempo map
        const low_raw = (counts.tempo_events * EntitySizes.TEMPO_EVENT) +
            1024; // Overhead

        // SCRATCH: JSON serialization (scales with largest payload)
        // Now handles all toJson calls including tracks, items, skeleton, metering, toggles
        const scratch_raw = @max(
            counts.tracks * 600, // ~600 bytes per track JSON (with GUID)
            counts.items * 256, // ~256 bytes per item JSON
        ) + 128 * 1024; // Increased base for skeleton (~200B/track), metering, toggles, errors

        // Apply headroom multiplier
        var high = high_raw * MemoryBounds.HEADROOM_MULTIPLIER;
        var medium = medium_raw * MemoryBounds.HEADROOM_MULTIPLIER;
        var low = low_raw * MemoryBounds.HEADROOM_MULTIPLIER;
        var scratch = scratch_raw * MemoryBounds.HEADROOM_MULTIPLIER;

        // Ensure minimums per tier (reasonable defaults)
        high = @max(high, 256 * 1024); // 256KB minimum
        medium = @max(medium, 1 * 1024 * 1024); // 1MB minimum
        low = @max(low, 32 * 1024); // 32KB minimum
        scratch = @max(scratch, 2560 * 1024); // 2.5MB minimum (action enumeration needs ~2MB)

        // Calculate total and check against bounds
        const total = (high * 2) + (medium * 2) + (low * 2) + scratch;

        // Apply floor: if total < 20 MB, scale up proportionally
        if (total < MemoryBounds.MINIMUM_TOTAL) {
            const scale_factor = @as(f64, @floatFromInt(MemoryBounds.MINIMUM_TOTAL)) /
                @as(f64, @floatFromInt(total));
            high = @intFromFloat(@as(f64, @floatFromInt(high)) * scale_factor);
            medium = @intFromFloat(@as(f64, @floatFromInt(medium)) * scale_factor);
            low = @intFromFloat(@as(f64, @floatFromInt(low)) * scale_factor);
            scratch = @intFromFloat(@as(f64, @floatFromInt(scratch)) * scale_factor);
        }

        // Apply ceiling: if total > 200 MB, scale down proportionally
        // (recalculate after potential floor scaling)
        const total_after_floor = (high * 2) + (medium * 2) + (low * 2) + scratch;
        if (total_after_floor > MemoryBounds.MAXIMUM_TOTAL) {
            const scale_factor = @as(f64, @floatFromInt(MemoryBounds.MAXIMUM_TOTAL)) /
                @as(f64, @floatFromInt(total_after_floor));
            high = @intFromFloat(@as(f64, @floatFromInt(high)) * scale_factor);
            medium = @intFromFloat(@as(f64, @floatFromInt(medium)) * scale_factor);
            low = @intFromFloat(@as(f64, @floatFromInt(low)) * scale_factor);
            scratch = @intFromFloat(@as(f64, @floatFromInt(scratch)) * scale_factor);
        }

        return .{
            .high = high,
            .medium = medium,
            .low = low,
            .scratch = scratch,
        };
    }

    /// Create default sizes (for tests or when API not available)
    pub fn defaults() CalculatedSizes {
        return .{
            .high = ArenaSizes.HIGH,
            .medium = ArenaSizes.MEDIUM,
            .low = ArenaSizes.LOW,
            .scratch = ArenaSizes.SCRATCH,
        };
    }

    /// Format sizes for logging
    pub fn format(self: CalculatedSizes, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "HIGH={d}KB MEDIUM={d}KB LOW={d}KB SCRATCH={d}KB total={d}MB", .{
            self.high / 1024,
            self.medium / 1024,
            self.low / 1024,
            self.scratch / 1024,
            self.totalAllocated() / (1024 * 1024),
        }) catch null;
    }
};

pub const TieredArenas = struct {
    high: DoubleBufferedState(HighTierState),
    medium: DoubleBufferedState(MediumTierState),
    low: DoubleBufferedState(LowTierState),
    scratch: FrameArena,
    sizes: CalculatedSizes, // Store sizes for diagnostics

    const Self = @This();

    /// Initialize all tiered arenas with calculated sizes
    /// Use `initWithSizes()` for production with project-specific sizes
    /// Use `init()` for tests or when API not available
    pub fn initWithSizes(backing: Allocator, sizes: CalculatedSizes) !Self {
        var self: Self = undefined;
        self.sizes = sizes;

        // Initialize HIGH tier
        self.high = try DoubleBufferedState(HighTierState).init(backing, sizes.high);
        errdefer self.high.deinit(backing);

        // Initialize MEDIUM tier
        self.medium = try DoubleBufferedState(MediumTierState).init(backing, sizes.medium);
        errdefer self.medium.deinit(backing);

        // Initialize LOW tier
        self.low = try DoubleBufferedState(LowTierState).init(backing, sizes.low);
        errdefer self.low.deinit(backing);

        // Initialize SCRATCH arena
        self.scratch = try FrameArena.init(backing, sizes.scratch);

        return self;
    }

    /// Initialize with default sizes (for tests or when API not available)
    pub fn init(backing: Allocator) !Self {
        return initWithSizes(backing, CalculatedSizes.defaults());
    }

    /// Clean up all arenas
    pub fn deinit(self: *Self, backing: Allocator) void {
        self.high.deinit(backing);
        self.medium.deinit(backing);
        self.low.deinit(backing);
        self.scratch.deinit(backing);
        self.* = undefined;
    }

    /// Resize all arenas to new sizes.
    /// Call this on project change when entity counts have changed significantly.
    /// Invalidates all existing state - caller must repopulate.
    pub fn resize(self: *Self, backing: Allocator, new_sizes: CalculatedSizes) !void {
        // Deinit all existing arenas
        self.high.deinit(backing);
        self.medium.deinit(backing);
        self.low.deinit(backing);
        self.scratch.deinit(backing);

        // Reinitialize with new sizes
        self.sizes = new_sizes;

        // Initialize HIGH tier
        self.high = try DoubleBufferedState(HighTierState).init(backing, new_sizes.high);
        errdefer self.high.deinit(backing);

        // Initialize MEDIUM tier
        self.medium = try DoubleBufferedState(MediumTierState).init(backing, new_sizes.medium);
        errdefer self.medium.deinit(backing);

        // Initialize LOW tier
        self.low = try DoubleBufferedState(LowTierState).init(backing, new_sizes.low);
        errdefer self.low.deinit(backing);

        // Initialize SCRATCH arena
        self.scratch = try FrameArena.init(backing, new_sizes.scratch);
    }

    /// Check if resize is warranted based on new counts.
    /// Returns true if new allocation differs by more than threshold from current.
    pub fn shouldResize(self: *const Self, new_sizes: CalculatedSizes, threshold_percent: u8) bool {
        const current_total = self.sizes.totalAllocated();
        const new_total = new_sizes.totalAllocated();

        // Calculate percentage difference
        const larger = @max(current_total, new_total);
        const smaller = @min(current_total, new_total);

        if (larger == 0) return false;

        const diff_percent = ((larger - smaller) * 100) / larger;
        return diff_percent >= threshold_percent;
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

    /// Check if memory warning threshold exceeded (any tier > 80% peak utilization)
    pub fn isMemoryWarning(self: *const Self) bool {
        return self.usage().isMemoryWarning();
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

        /// Get peak utilization percentage for a tier (0-100)
        fn utilizationPercent(peak: usize, capacity: usize) u8 {
            if (capacity == 0) return 0;
            return @intCast(@min(100, (peak * 100) / capacity));
        }

        /// Get max peak utilization across all tiers (0-100)
        pub fn maxPeakUtilization(self: DiagnosticUsage) u8 {
            const high_util = utilizationPercent(self.high_peak, self.high_capacity);
            const medium_util = utilizationPercent(self.medium_peak, self.medium_capacity);
            const low_util = utilizationPercent(self.low_peak, self.low_capacity);
            return @max(high_util, @max(medium_util, low_util));
        }

        /// Check if memory warning threshold exceeded (any tier > 80% peak utilization)
        pub fn isMemoryWarning(self: DiagnosticUsage) bool {
            return self.maxPeakUtilization() >= 80;
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
    arenas.high.currentState().transport.bpm = 140.0; // Use non-default value

    // Begin frame 1
    try arenas.beginFrame(1);

    // Previous should have our value
    try testing.expectEqual(@as(f64, 140.0), arenas.high.previousState().transport.bpm);

    // Current should be reset to default (bpm defaults to 120)
    try testing.expectEqual(@as(f64, 120.0), arenas.high.currentState().transport.bpm);
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

// =============================================================================
// Arena Sizing Tests
// =============================================================================

test "CalculatedSizes defaults match ArenaSizes" {
    const defaults = CalculatedSizes.defaults();
    try testing.expectEqual(ArenaSizes.HIGH, defaults.high);
    try testing.expectEqual(ArenaSizes.MEDIUM, defaults.medium);
    try testing.expectEqual(ArenaSizes.LOW, defaults.low);
    try testing.expectEqual(ArenaSizes.SCRATCH, defaults.scratch);
}

test "CalculatedSizes empty project gets minimum floor" {
    const counts = EntityCounts{}; // All zeros
    const sizes = CalculatedSizes.fromCounts(counts);

    // Total should be at or near minimum (20 MB) - allow tolerance for rounding
    const total = sizes.totalAllocated();
    const tolerance = 1024 * 1024; // 1 MB tolerance for rounding
    try testing.expect(total >= MemoryBounds.MINIMUM_TOTAL - tolerance);
    try testing.expect(total <= MemoryBounds.MINIMUM_TOTAL + tolerance);
}

test "CalculatedSizes typical project stays within bounds" {
    const counts = EntityCounts{
        .tracks = 50,
        .items = 500,
        .markers = 20,
        .regions = 30,
        .fx_total = 100,
        .sends_total = 50,
        .tempo_events = 10,
    };
    const sizes = CalculatedSizes.fromCounts(counts);

    // Total should be within bounds (allow small rounding tolerance below minimum)
    const total = sizes.totalAllocated();
    const tolerance = 1024 * 1024; // 1 MB tolerance for rounding
    try testing.expect(total >= MemoryBounds.MINIMUM_TOTAL - tolerance);
    try testing.expect(total <= MemoryBounds.MAXIMUM_TOTAL);
}

test "CalculatedSizes extreme project hits ceiling" {
    const counts = EntityCounts{
        .tracks = 5000,
        .items = 50000,
        .markers = 2000,
        .regions = 2000,
        .fx_total = 20000,
        .sends_total = 10000,
        .tempo_events = 1000,
    };
    const sizes = CalculatedSizes.fromCounts(counts);

    // Total should be capped at maximum (200 MB)
    const total = sizes.totalAllocated();
    try testing.expect(total <= MemoryBounds.MAXIMUM_TOTAL);
}

test "CalculatedSizes format produces valid string" {
    const sizes = CalculatedSizes.defaults();
    var buf: [256]u8 = undefined;
    const formatted = sizes.format(&buf);
    try testing.expect(formatted != null);
    try testing.expect(formatted.?.len > 0);
}

test "EntityCounts format produces valid string" {
    const counts = EntityCounts{
        .tracks = 10,
        .items = 100,
        .markers = 5,
        .regions = 10,
        .fx_total = 20,
        .sends_total = 8,
        .tempo_events = 3,
    };
    var buf: [256]u8 = undefined;
    const formatted = counts.format(&buf);
    try testing.expect(formatted != null);
    try testing.expect(formatted.?.len > 0);
}

test "TieredArenas initWithSizes uses provided sizes" {
    const custom_sizes = CalculatedSizes{
        .high = 128 * 1024, // 128KB
        .medium = 512 * 1024, // 512KB
        .low = 32 * 1024, // 32KB
        .scratch = 128 * 1024, // 128KB
    };

    var arenas = try TieredArenas.initWithSizes(testing.allocator, custom_sizes);
    defer arenas.deinit(testing.allocator);

    const usage = arenas.usage();
    try testing.expectEqual(custom_sizes.high, usage.high_capacity);
    try testing.expectEqual(custom_sizes.medium, usage.medium_capacity);
    try testing.expectEqual(custom_sizes.low, usage.low_capacity);
    try testing.expectEqual(custom_sizes.scratch, usage.scratch_capacity);
}

test "TieredArenas resize changes capacities" {
    const initial_sizes = CalculatedSizes{
        .high = 64 * 1024, // 64KB
        .medium = 256 * 1024, // 256KB
        .low = 16 * 1024, // 16KB
        .scratch = 64 * 1024, // 64KB
    };

    var arenas = try TieredArenas.initWithSizes(testing.allocator, initial_sizes);
    defer arenas.deinit(testing.allocator);

    // Verify initial sizes
    var usage = arenas.usage();
    try testing.expectEqual(initial_sizes.high, usage.high_capacity);
    try testing.expectEqual(initial_sizes.medium, usage.medium_capacity);

    // Resize to larger sizes
    const new_sizes = CalculatedSizes{
        .high = 128 * 1024, // 128KB
        .medium = 512 * 1024, // 512KB
        .low = 32 * 1024, // 32KB
        .scratch = 128 * 1024, // 128KB
    };

    try arenas.resize(testing.allocator, new_sizes);

    // Verify new sizes
    usage = arenas.usage();
    try testing.expectEqual(new_sizes.high, usage.high_capacity);
    try testing.expectEqual(new_sizes.medium, usage.medium_capacity);
    try testing.expectEqual(new_sizes.low, usage.low_capacity);
    try testing.expectEqual(new_sizes.scratch, usage.scratch_capacity);
}

test "TieredArenas resize preserves functionality" {
    const initial_sizes = CalculatedSizes{
        .high = 64 * 1024,
        .medium = 256 * 1024,
        .low = 16 * 1024,
        .scratch = 64 * 1024,
    };

    var arenas = try TieredArenas.initWithSizes(testing.allocator, initial_sizes);
    defer arenas.deinit(testing.allocator);

    // Use the arenas
    try arenas.beginFrame(0);
    arenas.high.currentState().transport.bpm = 140.0;

    // Resize
    const new_sizes = CalculatedSizes{
        .high = 128 * 1024,
        .medium = 512 * 1024,
        .low = 32 * 1024,
        .scratch = 128 * 1024,
    };
    try arenas.resize(testing.allocator, new_sizes);

    // After resize, state should be reset to default (bpm defaults to 120)
    try testing.expectEqual(@as(f64, 120.0), arenas.high.currentState().transport.bpm);

    // Should still be functional after resize
    try arenas.beginFrame(1);
    arenas.high.currentState().transport.bpm = 160.0;
    try testing.expectEqual(@as(f64, 160.0), arenas.high.currentState().transport.bpm);
}

test "DiagnosticUsage isMemoryWarning threshold" {
    // Under threshold (79%)
    const usage_ok = TieredArenas.DiagnosticUsage{
        .high_used = 0,
        .high_capacity = 1000,
        .high_peak = 790,
        .medium_used = 0,
        .medium_capacity = 1000,
        .medium_peak = 500,
        .low_used = 0,
        .low_capacity = 1000,
        .low_peak = 300,
        .scratch_used = 0,
        .scratch_capacity = 1000,
        .frame_count = 0,
    };
    try testing.expect(!usage_ok.isMemoryWarning());
    try testing.expectEqual(@as(u8, 79), usage_ok.maxPeakUtilization());

    // At threshold (80%)
    const usage_warning = TieredArenas.DiagnosticUsage{
        .high_used = 0,
        .high_capacity = 1000,
        .high_peak = 800,
        .medium_used = 0,
        .medium_capacity = 1000,
        .medium_peak = 500,
        .low_used = 0,
        .low_capacity = 1000,
        .low_peak = 300,
        .scratch_used = 0,
        .scratch_capacity = 1000,
        .frame_count = 0,
    };
    try testing.expect(usage_warning.isMemoryWarning());
    try testing.expectEqual(@as(u8, 80), usage_warning.maxPeakUtilization());

    // Over threshold in medium tier (90%)
    const usage_medium_high = TieredArenas.DiagnosticUsage{
        .high_used = 0,
        .high_capacity = 1000,
        .high_peak = 500,
        .medium_used = 0,
        .medium_capacity = 1000,
        .medium_peak = 900,
        .low_used = 0,
        .low_capacity = 1000,
        .low_peak = 300,
        .scratch_used = 0,
        .scratch_capacity = 1000,
        .frame_count = 0,
    };
    try testing.expect(usage_medium_high.isMemoryWarning());
    try testing.expectEqual(@as(u8, 90), usage_medium_high.maxPeakUtilization());
}

test "TieredArenas shouldResize detects significant changes" {
    const small_sizes = CalculatedSizes{
        .high = 64 * 1024,
        .medium = 256 * 1024,
        .low = 16 * 1024,
        .scratch = 64 * 1024,
    };

    var arenas = try TieredArenas.initWithSizes(testing.allocator, small_sizes);
    defer arenas.deinit(testing.allocator);

    // Same sizes: should NOT resize
    try testing.expect(!arenas.shouldResize(small_sizes, 20));

    // Slightly larger (10% increase): should NOT resize with 20% threshold
    const slightly_larger = CalculatedSizes{
        .high = 70 * 1024,
        .medium = 280 * 1024,
        .low = 18 * 1024,
        .scratch = 70 * 1024,
    };
    try testing.expect(!arenas.shouldResize(slightly_larger, 20));

    // Much larger (2x): should resize
    const much_larger = CalculatedSizes{
        .high = 128 * 1024,
        .medium = 512 * 1024,
        .low = 32 * 1024,
        .scratch = 128 * 1024,
    };
    try testing.expect(arenas.shouldResize(much_larger, 20));

    // Much smaller (half): should resize
    const much_smaller = CalculatedSizes{
        .high = 32 * 1024,
        .medium = 128 * 1024,
        .low = 8 * 1024,
        .scratch = 32 * 1024,
    };
    try testing.expect(arenas.shouldResize(much_smaller, 20));
}
