/// Shared types for REAPER API abstraction.
/// These types are used by both the real API wrapper and mock implementations.
const std = @import("std");

/// Time conversion result: seconds to beats info
pub const BeatsInfo = struct {
    beats: f64, // Total beats from project start (in time sig denominator units)
    measures: c_int, // Measure number (1-based)
    beats_in_measure: f64, // Beat position within measure (0-indexed with fraction)
    time_sig_denom: c_int, // Time signature denominator
};

/// Position-aware tempo info
pub const TempoAtPosition = struct {
    bpm: f64,
    timesig_num: c_int,
    timesig_denom: c_int,
};

/// Tempo marker data
pub const TempoMarker = struct {
    position: f64, // Time position in seconds
    position_beats: f64, // Beat position (total beats from project start)
    bpm: f64,
    timesig_num: c_int,
    timesig_denom: c_int,
    linear_tempo: bool, // True = linear tempo transition to next marker
};

/// Time selection bounds
pub const TimeSelection = struct {
    start: f64,
    end: f64,
};

/// Time signature info
pub const TimeSignature = struct {
    bpm: f64,
    num: f64,
};

/// Marker/Region info
pub const MarkerInfo = struct {
    idx: c_int, // enumeration index
    id: c_int, // displayed marker/region ID
    is_region: bool,
    pos: f64,
    end: f64, // only valid for regions
    name: []const u8,
    color: c_int,
};

/// Marker count summary
pub const MarkerCount = struct {
    total: c_int,
    markers: c_int,
    regions: c_int,
};
