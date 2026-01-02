/// Backend interface validation for REAPER API implementations.
///
/// Provides comptime validation that a type implements all required methods.
/// Use this to get clear compile errors when methods are missing, rather than
/// cryptic errors at call sites deep in implementation code.
///
/// Usage:
///   comptime { validateBackend(RealBackend); }
///   comptime { validateBackend(MockBackend); }

/// Validates that a type has all required backend methods.
/// Call this at comptime to get clear errors for missing methods.
pub fn validateBackend(comptime T: type) void {
    const required_methods = .{
        // Transport
        "playState",
        "playPosition",
        "cursorPosition",
        "timePrecise",
        "timePreciseMs",
        "runCommand",
        "setCursorPos",

        // Time conversion
        "timeToBeats",
        "beatsToTime",
        "barBeatToTime",

        // Tempo / Time signature
        "timeSignature",
        "getTempoAtPosition",
        "tempoMarkerCount",
        "getTempoMarker",
        "getBarOffset",
        "getTimeSignatureNumerator",
        "getTimeSignatureDenominator",
        "setTempo",
        "setTimeSignature",

        // Time selection
        "timeSelection",
        "setTimeSelection",
        "clearTimeSelection",

        // Repeat
        "getRepeat",
        "setRepeat",

        // Project info
        "projectLength",
        "projectStateChangeCount",
        "isDirty",
        "markDirty",

        // Command state
        "getCommandState",
        "isMetronomeEnabled",
        "getMetronomeVolume",
        "setMetronomeVolume",

        // Undo/Redo
        "canUndo",
        "canRedo",
        "doUndo",
        "doRedo",
        "undoBeginBlock",
        "undoEndBlock",

        // Tracks
        "trackCount",
        "getTrackByIdx",
        "getTrackByUnifiedIdx",
        "masterTrack",
        "getTrackNameStr",
        "getTrackVolume",
        "getTrackPan",
        "getTrackMute",
        "getTrackSolo",
        "getTrackRecArm",
        "getTrackRecMon",
        "getTrackFxEnabled",
        "getTrackSelected",
        "getTrackColor",
        "isMasterMuted",
        "isMasterSoloed",
        "setTrackVolume",
        "setTrackPan",
        "setTrackMute",
        "setTrackSolo",
        "setTrackRecArm",
        "setTrackRecMon",
        "setTrackFxEnabled",
        "setTrackSelected",
        "csurfSetVolume",
        "csurfSetPan",
        "csurfSetMute",
        "csurfSetSolo",
        "csurfSetRecArm",
        "csurfSetRecMon",
        "csurfFlushUndo",

        // Items
        "trackItemCount",
        "getItemByIdx",
        "getItemPosition",
        "getItemLength",
        "getItemColor",
        "getItemLocked",
        "getItemSelected",
        "getItemActiveTakeIdx",
        "getItemNotes",
        "getItemGUID",
        "setItemPosition",
        "setItemColor",
        "setItemLocked",
        "setItemSelected",
        "setItemNotes",
        "setItemActiveTake",
        "deleteItem",

        // Takes
        "itemTakeCount",
        "getTakeByIdx",
        "getItemActiveTake",
        "getTakeNameStr",
        "getTakeGUID",
        "getTakeStartOffset",
        "getTakePlayrate",
        "isTakeMIDI",
        "getTakeSource",
        "getMediaSourceChannels",

        // Markers
        "markerCount",
        "enumMarker",
        "addMarker",
        "addMarkerWithId",
        "addRegion",
        "addRegionWithId",
        "updateMarker",
        "updateRegion",
        "deleteMarker",
        "deleteRegion",

        // Metering
        "getTrackPeakInfo",

        // ExtState
        "getExtStateValue",
        "setExtStateValue",
        "getProjExtStateValue",
        "setProjExtStateValue",

        // Project notes
        "getProjectNotes",

        // Named command
        "namedCommandLookup",

        // MIDI
        "sendMidiCC",
        "sendMidiPC",

        // UI
        "updateTimeline",
    };

    inline for (required_methods) |method| {
        if (!@hasDecl(T, method)) {
            @compileError("Backend missing required method: " ++ method);
        }
    }
}
