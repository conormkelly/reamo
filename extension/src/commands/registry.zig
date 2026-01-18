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
const fx_plugin = @import("fx_plugin.zig");
const send = @import("send.zig");
const receive = @import("receive.zig");
const hw_output = @import("hw_output.zig");
const playlist_cmds = @import("playlist.zig");
const preferences = @import("preferences.zig");
const debug = @import("debug.zig");
const track_subs = @import("track_subs.zig");
const peaks_subs = @import("peaks_subs.zig");
const routing_subs = @import("routing_subs.zig");
const trackfx_subs = @import("trackfx_subs.zig");
const trackfxparam_subs = @import("trackfxparam_subs.zig");
const trackfxparam = @import("trackfxparam.zig");
const inputs = @import("inputs.zig");

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
    .{ "item/toggleSelect", items.handleItemToggleSelect },
    .{ "item/selectNext", items.handleItemSelectNext },
    .{ "item/selectPrev", items.handleItemSelectPrev },
    .{ "item/getPeaks", items.handleItemGetPeaks },
    // On-demand item data (sparse field fetch)
    .{ "item/getNotes", items.handleItemGetNotes },
    .{ "item/getTakes", items.handleItemGetTakes },

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
    .{ "track/setSoloExclusive", tracks.handleSetSoloExclusive },
    .{ "track/setRecArm", tracks.handleSetRecArm },
    .{ "track/setRecMon", tracks.handleSetRecMon },
    .{ "track/setFxEnabled", tracks.handleSetFxEnabled },
    .{ "track/setSelected", tracks.handleSetSelected },
    .{ "track/unselectAll", tracks.handleDeselectAll },
    .{ "track/rename", tracks.handleRename },
    .{ "track/setColor", tracks.handleSetColor },
    .{ "track/create", tracks.handleCreate },
    .{ "track/duplicate", tracks.handleDuplicate },
    .{ "track/duplicateSelected", tracks.handleDuplicateSelected },
    .{ "track/delete", tracks.handleDelete },
    .{ "track/deleteSelected", tracks.handleDeleteSelected },
    .{ "meter/clearClip", tracks.handleClearClip },
    // On-demand track data (sparse field fetch)
    .{ "track/getFx", tracks.handleGetFx },
    .{ "track/getSends", tracks.handleGetSends },
    .{ "track/getHwOutputs", tracks.handleGetHwOutputs },
    .{ "track/getInput", inputs.handleGetInput },
    .{ "track/setInput", inputs.handleSetInput },

    // Input enumeration
    .{ "input/enumerateAudio", inputs.handleEnumerateAudio },
    .{ "input/enumerateMidi", inputs.handleEnumerateMidi },

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
    // NOTE: undo/begin and undo/end deliberately removed - they're dangerous with multiple clients
    // as REAPER doesn't support nested undo blocks. See research/REAPER_UNDO_BLOCKS.md
    .{ "undo/do", undo.handleUndo },
    .{ "redo/do", undo.handleRedo },

    // Actions
    .{ "action/getToggleState", actions.handleGetToggleState },
    .{ "action/execute", actions.handleExecuteCommand },
    .{ "action/executeByName", actions.handleExecuteByName },
    .{ "action/getActions", actions.handleGetActions },

    // Gestures
    .{ "gesture/start", gesture.handleStart },
    .{ "gesture/end", gesture.handleEnd },

    // Toggle State Subscriptions
    .{ "actionToggleState/subscribe", toggle_state.handleSubscribe },
    .{ "actionToggleState/unsubscribe", toggle_state.handleUnsubscribe },

    // MIDI
    .{ "midi/cc", midi.handleCC },
    .{ "midi/pc", midi.handlePC },
    .{ "midi/noteOn", midi.handleNoteOn },
    .{ "midi/pitchBend", midi.handlePitchBend },

    // Project Notes
    .{ "projectNotes/subscribe", project_notes.handleSubscribe },
    .{ "projectNotes/unsubscribe", project_notes.handleUnsubscribe },
    .{ "projectNotes/get", project_notes.handleGet },
    .{ "projectNotes/set", project_notes.handleSet },

    // Track FX (using trackFx/ prefix to match REAPER's TrackFX_* API family)
    .{ "trackFx/presetNext", fx.handlePresetNext },
    .{ "trackFx/presetPrev", fx.handlePresetPrev },
    .{ "trackFx/presetSet", fx.handlePresetSet },
    .{ "trackFx/setEnabled", fx.handleSetEnabled },
    .{ "trackFx/add", fx.handleAdd },
    .{ "trackFx/delete", fx.handleDelete },
    .{ "trackFx/move", fx.handleMove },
    .{ "trackFx/getParams", fx.handleGetParams },

    // FX Plugin Library (global plugin enumeration)
    .{ "fxPlugin/getList", fx_plugin.handleGetList },

    // Sends
    .{ "send/setVolume", send.handleSetVolume },
    .{ "send/setMute", send.handleSetMute },
    .{ "send/setPan", send.handleSetPan },
    .{ "send/setMode", send.handleSetMode },

    // Receives
    .{ "receive/setVolume", receive.handleSetVolume },
    .{ "receive/setMute", receive.handleSetMute },
    .{ "receive/setPan", receive.handleSetPan },
    .{ "receive/setMode", receive.handleSetMode },

    // Hardware Outputs
    .{ "hw/setVolume", hw_output.handleSetVolume },
    .{ "hw/setMute", hw_output.handleSetMute },
    .{ "hw/setPan", hw_output.handleSetPan },
    .{ "hw/setMode", hw_output.handleSetMode },

    // Playlists (Cue List)
    .{ "playlist/create", playlist_cmds.handleCreate },
    .{ "playlist/delete", playlist_cmds.handleDelete },
    .{ "playlist/rename", playlist_cmds.handleRename },
    .{ "playlist/addEntry", playlist_cmds.handleAddEntry },
    .{ "playlist/removeEntry", playlist_cmds.handleRemoveEntry },
    .{ "playlist/setLoopCount", playlist_cmds.handleSetLoopCount },
    .{ "playlist/setStopAfterLast", playlist_cmds.handleSetStopAfterLast },
    .{ "playlist/reorderEntry", playlist_cmds.handleReorderEntry },
    .{ "playlist/play", playlist_cmds.handlePlay },
    .{ "playlist/playFromEntry", playlist_cmds.handlePlayFromEntry },
    .{ "playlist/pause", playlist_cmds.handlePause },
    .{ "playlist/stop", playlist_cmds.handleStop },
    .{ "playlist/next", playlist_cmds.handleNext },
    .{ "playlist/prev", playlist_cmds.handlePrev },
    .{ "playlist/advanceAfterLoop", playlist_cmds.handleAdvanceAfterLoop },

    // Preferences
    .{ "preferences/getSeekSettings", preferences.handleGetSeekSettings },
    .{ "preferences/setSeekSettings", preferences.handleSetSeekSettings },

    // Debug
    .{ "debug/memoryStats", debug.handleMemoryStats },

    // Track Subscriptions (viewport-driven polling)
    .{ "track/subscribe", track_subs.handleSubscribe },
    .{ "track/unsubscribe", track_subs.handleUnsubscribe },

    // Peaks Subscriptions (timeline waveforms)
    .{ "peaks/subscribe", peaks_subs.handleSubscribe },
    .{ "peaks/unsubscribe", peaks_subs.handleUnsubscribe },
    .{ "peaks/updateViewport", peaks_subs.handleUpdateViewport },

    // Routing Subscriptions (per-track sends/receives/hw outputs)
    .{ "routing/subscribe", routing_subs.handleSubscribe },
    .{ "routing/unsubscribe", routing_subs.handleUnsubscribe },

    // Track FX Subscriptions (per-track FX chain)
    .{ "trackFx/subscribe", trackfx_subs.handleSubscribe },
    .{ "trackFx/unsubscribe", trackfx_subs.handleUnsubscribe },

    // Track FX Parameter Subscriptions (individual FX param values)
    .{ "trackFxParams/subscribe", trackfxparam_subs.handleSubscribe },
    .{ "trackFxParams/unsubscribe", trackfxparam_subs.handleUnsubscribe },

    // Track FX Parameter Control (set param values)
    .{ "trackFxParams/set", trackfxparam.handleSetParam },
};
