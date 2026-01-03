/// Comptime command registry - aggregates all handlers as a tuple for inline for dispatch.
///
/// This enables handlers to use `anytype` for the API parameter, allowing both
/// RealBackend (production) and MockBackend (testing) to be passed in.
///
/// The tuple is unrolled at comptime via `inline for`, so there's no runtime
/// loop overhead - each handler is called directly with the concrete type.

const transport = @import("transport.zig");
const markers = @import("markers.zig");
const regions = @import("regions.zig");
const items = @import("items.zig");
const takes = @import("takes.zig");
const time_sel = @import("time_sel.zig");
const repeat = @import("repeat.zig");
const tracks = @import("tracks.zig");
const tempo = @import("tempo.zig");
const timesig = @import("timesig.zig");
const metronome = @import("metronome.zig");
const master = @import("master.zig");
const extstate = @import("extstate.zig");
const undo = @import("undo.zig");
const actions = @import("actions.zig");
const gesture = @import("gesture.zig");
const toggle_state = @import("toggle_state.zig");
const midi = @import("midi.zig");
const project_notes = @import("project_notes.zig");
const fx = @import("fx.zig");
const send = @import("send.zig");

/// Comptime tuple of (command_name, handler_fn) pairs.
/// Used by dispatch() with inline for to call handlers with anytype.
pub const all = .{
    // Transport
    .{ "transport/play", transport.handlePlay },
    .{ "transport/stop", transport.handleStop },
    .{ "transport/pause", transport.handlePause },
    .{ "transport/record", transport.handleRecord },
    .{ "transport/playPause", transport.handlePlayPause },
    .{ "transport/seek", transport.handleSeek },
    .{ "transport/stopAndDelete", transport.handleStopAndDelete },
    .{ "transport/goStart", transport.handleGoStart },
    .{ "transport/goEnd", transport.handleGoEnd },
    .{ "transport/seekBeats", transport.handleSeekBeats },

    // Markers
    .{ "marker/add", markers.handleMarkerAdd },
    .{ "marker/update", markers.handleMarkerUpdate },
    .{ "marker/delete", markers.handleMarkerDelete },
    .{ "marker/goto", markers.handleMarkerGoto },
    .{ "marker/prev", markers.handleMarkerPrev },
    .{ "marker/next", markers.handleMarkerNext },

    // Regions
    .{ "region/add", regions.handleRegionAdd },
    .{ "region/update", regions.handleRegionUpdate },
    .{ "region/delete", regions.handleRegionDelete },
    .{ "region/goto", regions.handleRegionGoto },
    .{ "region/batch", regions.handleRegionBatch },

    // Items
    .{ "item/setActiveTake", items.handleItemSetActiveTake },
    .{ "item/move", items.handleItemMove },
    .{ "item/setColor", items.handleItemColor },
    .{ "item/setLock", items.handleItemLock },
    .{ "item/setNotes", items.handleItemNotes },
    .{ "item/delete", items.handleItemDelete },
    .{ "item/goto", items.handleItemGoto },
    .{ "item/select", items.handleItemSelect },
    .{ "item/selectInTimeSel", items.handleSelectInTimeSel },
    .{ "item/unselectAll", items.handleUnselectAll },
    .{ "item/getPeaks", items.handleItemGetPeaks },

    // Takes
    .{ "take/delete", takes.handleTakeDelete },
    .{ "take/cropToActive", takes.handleTakeCropToActive },
    .{ "take/next", takes.handleTakeNext },
    .{ "take/prev", takes.handleTakePrev },

    // Time Selection
    .{ "timeSelection/set", time_sel.handleSet },
    .{ "timeSelection/setByBars", time_sel.handleSetBars },
    .{ "timeSelection/clear", time_sel.handleClear },
    .{ "timeSelection/goStart", time_sel.handleGoStart },
    .{ "timeSelection/goEnd", time_sel.handleGoEnd },
    .{ "timeSelection/setStartAtCursor", time_sel.handleSetStart },
    .{ "timeSelection/setEndAtCursor", time_sel.handleSetEnd },

    // Repeat
    .{ "repeat/set", repeat.handleSet },
    .{ "repeat/toggle", repeat.handleToggle },

    // Tracks
    .{ "track/setVolume", tracks.handleSetVolume },
    .{ "track/setPan", tracks.handleSetPan },
    .{ "track/setMute", tracks.handleSetMute },
    .{ "track/setSolo", tracks.handleSetSolo },
    .{ "track/setRecArm", tracks.handleSetRecArm },
    .{ "track/setRecMon", tracks.handleSetRecMon },
    .{ "track/setFxEnabled", tracks.handleSetFxEnabled },
    .{ "track/setSelected", tracks.handleSetSelected },
    .{ "track/unselectAll", tracks.handleDeselectAll },
    .{ "track/rename", tracks.handleRename },
    .{ "track/create", tracks.handleCreate },
    .{ "track/duplicate", tracks.handleDuplicate },
    .{ "track/duplicateSelected", tracks.handleDuplicateSelected },
    .{ "track/delete", tracks.handleDelete },
    .{ "track/deleteSelected", tracks.handleDeleteSelected },
    .{ "meter/clearClip", tracks.handleClearClip },

    // Tempo
    .{ "tempo/set", tempo.handleSet },
    .{ "tempo/tap", tempo.handleTap },
    .{ "tempo/snap", tempo.handleSnap },
    .{ "tempo/getBarDuration", tempo.handleGetBarDuration },
    .{ "tempo/timeToBeats", tempo.handleTimeToBeats },
    .{ "tempo/barsToTime", tempo.handleBarsToTime },

    // Time Signature
    .{ "timesig/set", timesig.handleSet },

    // Metronome
    .{ "metronome/toggle", metronome.handleToggle },
    .{ "metronome/getVolume", metronome.handleGetVolume },
    .{ "metronome/setVolume", metronome.handleSetVolume },

    // Master
    .{ "master/toggleMono", master.handleToggleMono },

    // ExtState
    .{ "extstate/get", extstate.handleGet },
    .{ "extstate/set", extstate.handleSet },
    .{ "extstate/projGet", extstate.handleProjGet },
    .{ "extstate/projSet", extstate.handleProjSet },

    // Undo
    .{ "undo/add", undo.handleAdd },
    .{ "undo/begin", undo.handleBegin },
    .{ "undo/end", undo.handleEnd },
    .{ "undo/do", undo.handleUndo },
    .{ "redo/do", undo.handleRedo },

    // Actions
    .{ "action/getToggleState", actions.handleGetToggleState },
    .{ "action/execute", actions.handleExecuteCommand },
    .{ "action/executeByName", actions.handleExecuteByName },

    // Gestures
    .{ "gesture/start", gesture.handleStart },
    .{ "gesture/end", gesture.handleEnd },

    // Toggle State Subscriptions
    .{ "actionToggleState/subscribe", toggle_state.handleSubscribe },
    .{ "actionToggleState/unsubscribe", toggle_state.handleUnsubscribe },

    // MIDI
    .{ "midi/cc", midi.handleCC },
    .{ "midi/pc", midi.handlePC },

    // Project Notes
    .{ "projectNotes/subscribe", project_notes.handleSubscribe },
    .{ "projectNotes/unsubscribe", project_notes.handleUnsubscribe },
    .{ "projectNotes/get", project_notes.handleGet },
    .{ "projectNotes/set", project_notes.handleSet },

    // FX Presets
    .{ "fx/presetNext", fx.handlePresetNext },
    .{ "fx/presetPrev", fx.handlePresetPrev },
    .{ "fx/presetSet", fx.handlePresetSet },

    // Sends
    .{ "send/setVolume", send.handleSetVolume },
    .{ "send/setMute", send.handleSetMute },
};
