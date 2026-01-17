/// CSurf Dirty Flags - tracks what state needs re-polling after CSurf callbacks.
///
/// CSurf callbacks signal WHAT changed, dirty flags record it, main loop polls only dirty state.
/// This enables O(changes) polling instead of O(n) unconditional polling.
///
/// Thread safety: These flags are only accessed from REAPER's main thread
/// (CSurf callbacks and timer callback both run on main thread).
/// No atomics needed.
///
/// See: docs/architecture/CSURF_MIGRATION.md
///
const std = @import("std");

/// Research-backed constants from SWS Extension analysis
/// See: research/REAPER_CSURF_API_BEHAVIOUR.md
pub const SAFETY_POLL_INTERVAL: u32 = 60; // 2s at 30Hz (SWS-validated)
pub const VOL_CHANGE_THRESHOLD: f64 = 0.001; // ~0.01dB
pub const PAN_CHANGE_THRESHOLD: f64 = 0.005; // ~0.5%

/// Maximum tracks supported in bitsets. Projects with more tracks
/// trigger all_tracks_dirty fallback instead of per-track granularity.
pub const MAX_TRACKS: usize = 1024;

/// Dirty flags for CSurf push-based polling optimization.
/// Callbacks set flags, main loop consumes and clears them.
pub const DirtyFlags = struct {
    /// Validity guard - false between SetTrackListChange and rebuild().
    /// Track callbacks check this and bail early if false, preventing
    /// garbage lookups against a stale reverse_map.
    reverse_map_valid: bool = false,

    /// Per-track dirty flags (max 1024 tracks)
    track_dirty: std.StaticBitSet(MAX_TRACKS) = std.StaticBitSet(MAX_TRACKS).initEmpty(),
    fx_dirty: std.StaticBitSet(MAX_TRACKS) = std.StaticBitSet(MAX_TRACKS).initEmpty(),
    sends_dirty: std.StaticBitSet(MAX_TRACKS) = std.StaticBitSet(MAX_TRACKS).initEmpty(),

    /// Global dirty flags
    transport_dirty: bool = false,
    skeleton_dirty: bool = false,
    markers_dirty: bool = false,
    tempo_dirty: bool = false,

    /// Overflow fallback - set when track idx >= MAX_TRACKS.
    /// When true, poll ALL subscribed tracks instead of checking bitset.
    all_tracks_dirty: bool = false,

    /// Set a specific track as dirty (volume/pan/mute/solo/selection/recarm changed)
    pub fn setTrackDirty(self: *@This(), idx: usize) void {
        if (idx >= MAX_TRACKS) {
            self.all_tracks_dirty = true;
            return;
        }
        self.track_dirty.set(idx);
    }

    /// Set a specific track's FX as dirty (parameter changed)
    pub fn setFxDirty(self: *@This(), idx: usize) void {
        if (idx >= MAX_TRACKS) {
            self.all_tracks_dirty = true;
            return;
        }
        self.fx_dirty.set(idx);
    }

    /// Set a specific track's sends as dirty (send volume/pan changed)
    pub fn setSendsDirty(self: *@This(), idx: usize) void {
        if (idx >= MAX_TRACKS) {
            self.all_tracks_dirty = true;
            return;
        }
        self.sends_dirty.set(idx);
    }

    /// Consume track dirty flags - returns current state and clears.
    /// Returns struct with bitset copy and overflow flag.
    pub fn consumeTrackDirty(self: *@This()) struct { bits: std.StaticBitSet(MAX_TRACKS), all: bool } {
        const result = .{ .bits = self.track_dirty, .all = self.all_tracks_dirty };
        self.track_dirty = std.StaticBitSet(MAX_TRACKS).initEmpty();
        self.all_tracks_dirty = false;
        return result;
    }

    /// Consume FX dirty flags - returns current state and clears.
    pub fn consumeFxDirty(self: *@This()) struct { bits: std.StaticBitSet(MAX_TRACKS), all: bool } {
        const result = .{ .bits = self.fx_dirty, .all = self.all_tracks_dirty };
        self.fx_dirty = std.StaticBitSet(MAX_TRACKS).initEmpty();
        return result;
    }

    /// Consume sends dirty flags - returns current state and clears.
    pub fn consumeSendsDirty(self: *@This()) struct { bits: std.StaticBitSet(MAX_TRACKS), all: bool } {
        const result = .{ .bits = self.sends_dirty, .all = self.all_tracks_dirty };
        self.sends_dirty = std.StaticBitSet(MAX_TRACKS).initEmpty();
        return result;
    }

    /// Consume a global dirty flag - returns current state and clears.
    pub fn consumeGlobal(flag: *bool) bool {
        const was = flag.*;
        flag.* = false;
        return was;
    }

    /// Mark all tracks as dirty (used by ResetCachedVolPanStates and heartbeat)
    pub fn setAllTracksDirty(self: *@This()) void {
        self.all_tracks_dirty = true;
    }

    /// Clear all dirty flags (used on project switch, etc.)
    /// Note: Does NOT clear reverse_map_valid - only rebuild() sets it true.
    pub fn clearAll(self: *@This()) void {
        self.track_dirty = std.StaticBitSet(MAX_TRACKS).initEmpty();
        self.fx_dirty = std.StaticBitSet(MAX_TRACKS).initEmpty();
        self.sends_dirty = std.StaticBitSet(MAX_TRACKS).initEmpty();
        self.transport_dirty = false;
        self.skeleton_dirty = false;
        self.markers_dirty = false;
        self.tempo_dirty = false;
        self.all_tracks_dirty = false;
    }

    /// Check if any track-level dirty flags are set
    pub fn hasAnyTrackDirty(self: *const @This()) bool {
        return self.all_tracks_dirty or
            self.track_dirty.count() > 0 or
            self.fx_dirty.count() > 0 or
            self.sends_dirty.count() > 0;
    }

    /// Check if any global dirty flags are set
    pub fn hasAnyGlobalDirty(self: *const @This()) bool {
        return self.transport_dirty or
            self.skeleton_dirty or
            self.markers_dirty or
            self.tempo_dirty;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DirtyFlags init state" {
    var flags = DirtyFlags{};

    try std.testing.expect(!flags.reverse_map_valid);
    try std.testing.expect(!flags.transport_dirty);
    try std.testing.expect(!flags.skeleton_dirty);
    try std.testing.expect(!flags.all_tracks_dirty);
    try std.testing.expectEqual(@as(usize, 0), flags.track_dirty.count());
}

test "DirtyFlags setTrackDirty and consume" {
    var flags = DirtyFlags{};

    flags.setTrackDirty(5);
    flags.setTrackDirty(10);
    flags.setTrackDirty(100);

    try std.testing.expect(flags.track_dirty.isSet(5));
    try std.testing.expect(flags.track_dirty.isSet(10));
    try std.testing.expect(flags.track_dirty.isSet(100));
    try std.testing.expect(!flags.track_dirty.isSet(0));

    const consumed = flags.consumeTrackDirty();
    try std.testing.expect(consumed.bits.isSet(5));
    try std.testing.expect(consumed.bits.isSet(10));
    try std.testing.expect(!consumed.all);

    // After consume, should be cleared
    try std.testing.expectEqual(@as(usize, 0), flags.track_dirty.count());
}

test "DirtyFlags overflow fallback" {
    var flags = DirtyFlags{};

    // Track index >= 1024 triggers overflow
    flags.setTrackDirty(1500);
    try std.testing.expect(flags.all_tracks_dirty);

    const consumed = flags.consumeTrackDirty();
    try std.testing.expect(consumed.all);

    // After consume, overflow should be cleared
    try std.testing.expect(!flags.all_tracks_dirty);
}

test "DirtyFlags consumeGlobal" {
    var flags = DirtyFlags{};

    flags.transport_dirty = true;
    try std.testing.expect(DirtyFlags.consumeGlobal(&flags.transport_dirty));
    try std.testing.expect(!flags.transport_dirty);

    // Second consume returns false
    try std.testing.expect(!DirtyFlags.consumeGlobal(&flags.transport_dirty));
}

test "DirtyFlags clearAll preserves reverse_map_valid" {
    var flags = DirtyFlags{};

    flags.reverse_map_valid = true;
    flags.transport_dirty = true;
    flags.skeleton_dirty = true;
    flags.setTrackDirty(5);

    flags.clearAll();

    // reverse_map_valid should NOT be cleared
    try std.testing.expect(flags.reverse_map_valid);
    // Everything else should be cleared
    try std.testing.expect(!flags.transport_dirty);
    try std.testing.expect(!flags.skeleton_dirty);
    try std.testing.expectEqual(@as(usize, 0), flags.track_dirty.count());
}

test "DirtyFlags hasAnyTrackDirty" {
    var flags = DirtyFlags{};

    try std.testing.expect(!flags.hasAnyTrackDirty());

    flags.setFxDirty(3);
    try std.testing.expect(flags.hasAnyTrackDirty());
}

test "constants are correct" {
    try std.testing.expectEqual(@as(u32, 60), SAFETY_POLL_INTERVAL);
    try std.testing.expectEqual(@as(usize, 1024), MAX_TRACKS);
}
