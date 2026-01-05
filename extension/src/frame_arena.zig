const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Frame Arena - Per-Frame Allocation for Polling Architecture
// =============================================================================
//
// Our polling architecture has frame-based lifetimes:
//   1. Poll REAPER → build complete state snapshot
//   2. Diff against previous frame
//   3. Serialize to JSON, broadcast
//   4. Previous frame's data is now garbage
//
// This is exactly what arenas are designed for: bulk allocate, use, reset.
// No individual frees, no fragmentation, no bookkeeping.
//
// Usage:
//   var arena = try FrameArena.init(backing_allocator, 64 * 1024 * 1024);
//   defer arena.deinit(backing_allocator);
//
//   // Each frame:
//   arena.reset();
//   const tracks = try arena.allocator().alloc(Track, count);
//   // ... use tracks ...
//   // No free needed - next reset() clears everything
// =============================================================================

/// A simple arena backed by a fixed buffer.
/// All allocations bump a pointer; reset() is O(1).
pub const FrameArena = struct {
    buffer: []u8,
    fba: std.heap.FixedBufferAllocator,

    /// Initialize with a buffer of the given size from the backing allocator.
    pub fn init(backing: Allocator, size: usize) !FrameArena {
        const buffer = try backing.alloc(u8, size);
        return .{
            .buffer = buffer,
            .fba = std.heap.FixedBufferAllocator.init(buffer),
        };
    }

    /// Get an allocator interface for this arena.
    pub fn allocator(self: *FrameArena) Allocator {
        return self.fba.allocator();
    }

    /// Reset the arena, freeing all allocations. O(1) operation.
    pub fn reset(self: *FrameArena) void {
        self.fba.reset();
    }

    /// Return the buffer to the backing allocator.
    pub fn deinit(self: *FrameArena, backing: Allocator) void {
        backing.free(self.buffer);
        self.* = undefined;
    }

    /// Get current usage stats for diagnostics.
    pub fn usage(self: *const FrameArena) Usage {
        return .{
            .used = self.fba.end_index,
            .capacity = self.buffer.len,
        };
    }

    pub const Usage = struct {
        used: usize,
        capacity: usize,

        pub fn percentUsed(self: Usage) f32 {
            if (self.capacity == 0) return 0;
            return @as(f32, @floatFromInt(self.used)) / @as(f32, @floatFromInt(self.capacity)) * 100.0;
        }
    };
};

// =============================================================================
// Double-Buffered State - Ping-Pong Pattern for Change Detection
// =============================================================================
//
// We need two frames of state (current and previous) for change detection.
// Double buffering with arena swap eliminates the 2.5MB memcpy per frame.
//
// Usage:
//   var state = try DoubleBufferedState(FrameState).init(backing, arena_size);
//   defer state.deinit(backing);
//
//   // Each frame:
//   try state.beginFrame();
//   const alloc = state.currentAllocator();
//   state.currentState().tracks = try pollTracks(alloc, api);
//   if (!state.currentState().eql(state.previousState())) {
//       broadcast(state.currentState().toJson(alloc));
//   }
//   // No copy! Next beginFrame() swaps arenas.
// =============================================================================

/// Generic double-buffered state using two arenas.
/// `StateType` must have an `empty()` function returning a default value.
pub fn DoubleBufferedState(comptime StateType: type) type {
    // Validate StateType has required interface
    comptime {
        if (!@hasDecl(StateType, "empty")) {
            @compileError("StateType must have 'empty' function");
        }
    }

    return struct {
        arenas: [2]FrameArena,
        states: [2]*StateType,
        current: u1 = 0,
        frame_count: u64 = 0,
        peak_usage: [2]usize = .{ 0, 0 },

        const Self = @This();

        /// Initialize both arenas and allocate initial state structs.
        pub fn init(backing: Allocator, arena_size: usize) !Self {
            var self: Self = .{
                .arenas = undefined,
                .states = undefined,
            };

            // Initialize first arena
            self.arenas[0] = try FrameArena.init(backing, arena_size);
            errdefer self.arenas[0].deinit(backing);

            // Initialize second arena
            self.arenas[1] = try FrameArena.init(backing, arena_size);
            errdefer self.arenas[1].deinit(backing);

            // Allocate initial state structs from their respective arenas
            self.states[0] = try self.arenas[0].allocator().create(StateType);
            self.states[0].* = StateType.empty();

            self.states[1] = try self.arenas[1].allocator().create(StateType);
            self.states[1].* = StateType.empty();

            return self;
        }

        /// Free both arenas and their buffers.
        pub fn deinit(self: *Self, backing: Allocator) void {
            self.arenas[0].deinit(backing);
            self.arenas[1].deinit(backing);
            self.* = undefined;
        }

        /// Begin a new frame. Swaps to the other buffer and resets it.
        /// Call this at the START of each frame before any allocations.
        pub fn beginFrame(self: *Self) !void {
            // Track peak usage before resetting
            const current_usage = self.arenas[self.current].usage().used;
            self.peak_usage[self.current] = @max(self.peak_usage[self.current], current_usage);

            // Swap to other buffer
            self.current = 1 - self.current;

            // Reset the arena we're about to use (frees all previous-previous frame data)
            self.arenas[self.current].reset();

            // Allocate fresh state struct
            self.states[self.current] = try self.arenas[self.current].allocator().create(StateType);
            self.states[self.current].* = StateType.empty();

            self.frame_count += 1;
        }

        /// Get the current frame's state (mutable).
        pub fn currentState(self: *Self) *StateType {
            return self.states[self.current];
        }

        /// Get the previous frame's state (read-only).
        pub fn previousState(self: *const Self) *const StateType {
            return self.states[1 - self.current];
        }

        /// Get allocator for current frame. All allocations from this
        /// allocator will be freed on the next-next beginFrame() call.
        pub fn currentAllocator(self: *Self) Allocator {
            return self.arenas[self.current].allocator();
        }

        /// Get usage statistics for diagnostics.
        pub fn usage(self: *const Self) DiagnosticUsage {
            return .{
                .current_used = self.arenas[self.current].usage().used,
                .previous_used = self.arenas[1 - self.current].usage().used,
                .capacity = self.arenas[0].buffer.len,
                .peak_usage = @max(self.peak_usage[0], self.peak_usage[1]),
                .frame_count = self.frame_count,
            };
        }

        pub const DiagnosticUsage = struct {
            current_used: usize,
            previous_used: usize,
            capacity: usize,
            peak_usage: usize,
            frame_count: u64,

            pub fn peakPercentUsed(self: DiagnosticUsage) f32 {
                if (self.capacity == 0) return 0;
                return @as(f32, @floatFromInt(self.peak_usage)) / @as(f32, @floatFromInt(self.capacity)) * 100.0;
            }
        };
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "FrameArena basic allocation" {
    var arena = try FrameArena.init(testing.allocator, 1024);
    defer arena.deinit(testing.allocator);

    const alloc = arena.allocator();

    // Allocate some data
    const data = try alloc.alloc(u8, 100);
    @memset(data, 0xAB);

    try testing.expectEqual(@as(u8, 0xAB), data[0]);
    try testing.expectEqual(@as(u8, 0xAB), data[99]);

    // Usage should reflect allocation
    const u = arena.usage();
    try testing.expect(u.used >= 100);
    try testing.expect(u.capacity == 1024);
}

test "FrameArena reset clears allocations" {
    var arena = try FrameArena.init(testing.allocator, 1024);
    defer arena.deinit(testing.allocator);

    const alloc = arena.allocator();

    // Fill most of the arena
    _ = try alloc.alloc(u8, 800);
    try testing.expect(arena.usage().used >= 800);

    // Reset should clear
    arena.reset();
    try testing.expectEqual(@as(usize, 0), arena.usage().used);

    // Can allocate again
    _ = try alloc.alloc(u8, 800);
    try testing.expect(arena.usage().used >= 800);
}

test "FrameArena allocation failure when full" {
    var arena = try FrameArena.init(testing.allocator, 256);
    defer arena.deinit(testing.allocator);

    const alloc = arena.allocator();

    // This should succeed
    _ = try alloc.alloc(u8, 100);

    // This should fail (not enough space)
    const result = alloc.alloc(u8, 200);
    try testing.expectError(error.OutOfMemory, result);
}

// Test state type for DoubleBufferedState
const TestState = struct {
    value: i32 = 0,
    data: []u8 = &.{},

    pub fn empty() TestState {
        return .{};
    }

    pub fn eql(self: *const TestState, other: *const TestState) bool {
        return self.value == other.value and std.mem.eql(u8, self.data, other.data);
    }
};

test "DoubleBufferedState initialization" {
    var dbs = try DoubleBufferedState(TestState).init(testing.allocator, 4096);
    defer dbs.deinit(testing.allocator);

    // Both states should be empty
    try testing.expectEqual(@as(i32, 0), dbs.currentState().value);
    try testing.expectEqual(@as(i32, 0), dbs.previousState().value);
}

test "DoubleBufferedState frame swap" {
    var dbs = try DoubleBufferedState(TestState).init(testing.allocator, 4096);
    defer dbs.deinit(testing.allocator);

    // Set value in frame 0
    dbs.currentState().value = 42;

    // Begin frame 1
    try dbs.beginFrame();

    // Previous should have our value, current should be empty
    try testing.expectEqual(@as(i32, 42), dbs.previousState().value);
    try testing.expectEqual(@as(i32, 0), dbs.currentState().value);

    // Set value in frame 1
    dbs.currentState().value = 100;

    // Begin frame 2
    try dbs.beginFrame();

    // Previous should have frame 1 value, current should be empty
    try testing.expectEqual(@as(i32, 100), dbs.previousState().value);
    try testing.expectEqual(@as(i32, 0), dbs.currentState().value);
}

test "DoubleBufferedState allocations from currentAllocator" {
    var dbs = try DoubleBufferedState(TestState).init(testing.allocator, 4096);
    defer dbs.deinit(testing.allocator);

    // Allocate data in frame 0
    const data0 = try dbs.currentAllocator().alloc(u8, 100);
    @memset(data0, 0xAA);
    dbs.currentState().data = data0;

    // Begin frame 1
    try dbs.beginFrame();

    // Previous frame's data should still be valid (different arena)
    try testing.expectEqual(@as(u8, 0xAA), dbs.previousState().data[0]);

    // Allocate data in frame 1
    const data1 = try dbs.currentAllocator().alloc(u8, 100);
    @memset(data1, 0xBB);
    dbs.currentState().data = data1;

    // Begin frame 2 - this resets arena 0 (frame 0's data)
    try dbs.beginFrame();

    // Previous frame's data (frame 1, arena 1) should still be valid
    try testing.expectEqual(@as(u8, 0xBB), dbs.previousState().data[0]);
}

test "DoubleBufferedState change detection pattern" {
    var dbs = try DoubleBufferedState(TestState).init(testing.allocator, 4096);
    defer dbs.deinit(testing.allocator);

    // Frame 0: set initial value
    dbs.currentState().value = 10;

    // Frame 1: change value
    try dbs.beginFrame();
    dbs.currentState().value = 20;

    // Should detect change
    try testing.expect(!dbs.currentState().eql(dbs.previousState()));

    // Frame 2: same value as frame 1
    try dbs.beginFrame();
    dbs.currentState().value = 20;

    // Should NOT detect change
    try testing.expect(dbs.currentState().eql(dbs.previousState()));
}

test "DoubleBufferedState tracks frame count" {
    var dbs = try DoubleBufferedState(TestState).init(testing.allocator, 4096);
    defer dbs.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 0), dbs.usage().frame_count);

    try dbs.beginFrame();
    try testing.expectEqual(@as(u64, 1), dbs.usage().frame_count);

    try dbs.beginFrame();
    try testing.expectEqual(@as(u64, 2), dbs.usage().frame_count);
}

test "DoubleBufferedState tracks peak usage" {
    var dbs = try DoubleBufferedState(TestState).init(testing.allocator, 4096);
    defer dbs.deinit(testing.allocator);

    // Allocate 500 bytes in frame 0
    _ = try dbs.currentAllocator().alloc(u8, 500);

    // Begin frame 1 - should record peak
    try dbs.beginFrame();

    // Allocate 1000 bytes in frame 1
    _ = try dbs.currentAllocator().alloc(u8, 1000);

    // Begin frame 2 - should record new peak
    try dbs.beginFrame();

    // Peak should be at least 1000 (plus overhead for state struct)
    try testing.expect(dbs.usage().peak_usage >= 1000);
}
