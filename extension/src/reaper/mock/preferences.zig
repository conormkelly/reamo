/// Mock preferences/config methods.
const state = @import("state.zig");

/// Preferences method implementations for MockBackend.
/// Called via @fieldParentPtr from the main MockBackend struct.
pub const PreferencesMethods = struct {
    // =========================================================================
    // Smooth seek config
    // =========================================================================

    pub fn getSmoothSeekEnabled(self: anytype) bool {
        self.recordCall(.getSmoothSeekEnabled);
        return self.smooth_seek_enabled;
    }

    pub fn setSmoothSeekEnabled(self: anytype, enabled: bool) void {
        self.recordCall(.setSmoothSeekEnabled);
        self.smooth_seek_enabled = enabled;
    }

    pub fn getSmoothSeekMeasures(self: anytype) c_int {
        self.recordCall(.getSmoothSeekMeasures);
        return self.smooth_seek_measures;
    }

    pub fn setSmoothSeekMeasures(self: anytype, measures: c_int) void {
        self.recordCall(.setSmoothSeekMeasures);
        self.smooth_seek_measures = measures;
    }

    pub fn getSeekMode(self: anytype) c_int {
        self.recordCall(.getSeekMode);
        return self.seek_mode;
    }

    pub fn setSeekMode(self: anytype, mode: c_int) void {
        self.recordCall(.setSeekMode);
        self.seek_mode = mode;
    }
};
