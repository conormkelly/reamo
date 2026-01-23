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

        // Loop points (for native looping)
        "getLoopPoints",
        "setLoopPoints",
        "clearLoopPoints",

        // Repeat
        "getRepeat",
        "setRepeat",

        // Smooth seek config
        "getSmoothSeekEnabled",
        "setSmoothSeekEnabled",
        "getSmoothSeekMeasures",
        "setSmoothSeekMeasures",
        "getSeekMode",
        "setSeekMode",

        // Project info
        "projectLength",
        "projectStateChangeCount",
        "isDirty",
        "markDirty",
        "getFrameRate",

        // Command state
        "getCommandState",
        "getCommandStateEx",
        "getSectionFromUniqueID",
        "enumerateActions",
        "reverseNamedCommandLookup",
        "enumInstalledFX",
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
        "setTrackColor",
        "getTrackFolderDepth",
        "formatTrackGuid",
        "getTrackIdx",
        "getSelectedTrackByIdx",
        "isMasterMuted",
        "isMasterSoloed",
        "getTrackPeakHoldDB",
        "setTrackVolume",
        "setTrackPan",
        "setTrackMute",
        "setTrackSolo",
        "setTrackRecArm",
        "setTrackRecMon",
        "setTrackFxEnabled",
        "setTrackSelected",
        "setTrackName",
        "insertTrack",
        "deleteTrackPtr",
        "csurfSetVolume",
        "csurfSetPan",
        "csurfSetMute",
        "csurfSetSolo",
        "csurfSetRecArm",
        "csurfSetRecMon",
        "csurfFlushUndo",

        // Pointer Validation
        "validateTrackPtr",
        "validateItemPtr",
        "validateTakePtr",

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
        "getRootSource",
        "getMediaSourceChannels",
        "getMediaItemTakePeaks",

        // AudioAccessor (for fallback peak generation)
        "makeTakeAccessor",
        "destroyTakeAccessor",
        "readAccessorSamples",

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

        // Track FX
        "trackFxCount",
        "trackFxGetName",
        "trackFxGetPresetIndex",
        "trackFxGetPreset",
        "trackFxNavigatePresets",
        "trackFxSetPresetByIndex",
        "trackFxGetEnabled",
        "trackFxSetEnabled",
        // FX management
        "trackFxAddByName",
        "trackFxDelete",
        "trackFxCopyToTrack",
        "trackFxGetGuid",

        // Track Sends/Receives
        "trackSendCount",
        "trackReceiveCount",
        "trackSendGetVolume",
        "trackSendGetPan",
        "trackSendGetMute",
        "trackSendGetMode",
        "trackSendGetDestTrack",
        "trackSendGetDestName",
        "trackSendSetVolume",
        "trackSendSetPan",
        "trackSendToggleMute",
        "trackSendSetMute",
        "trackSendSetMode",
        "trackReceiveGetVolume",
        "trackReceiveGetMute",
        "trackReceiveGetMode",
        "trackReceiveGetPan",
        "trackReceiveGetSrcTrack",
        "trackReceiveGetSrcName",
        "trackReceiveSetVolume",
        "trackReceiveSetMute",
        "trackReceiveSetPan",
        "trackReceiveSetMode",

        // Hardware Outputs
        "trackHwOutputCount",
        "trackHwOutputGetVolume",
        "trackHwOutputGetPan",
        "trackHwOutputGetMute",
        "trackHwOutputGetMode",
        "trackHwOutputGetDestChannel",
        "trackHwOutputSetVolume",
        "trackHwOutputSetPan",
        "trackHwOutputSetMute",
        "trackHwOutputSetMode",

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
        "sendNoteOn",
        "sendPitchBend",

        // UI
        "updateTimeline",

        // MIDI Editor (for section-specific action execution)
        "midiEditorGetActive",
        "midiEditorOnCommand",

        // Input enumeration
        "numAudioInputs",
        "audioInputName",
        "maxMidiInputs",
        "midiInputName",
        "getTrackRecInput",
        "setTrackRecInput",
    };

    inline for (required_methods) |method| {
        if (!@hasDecl(T, method)) {
            @compileError("Backend missing required method: " ++ method);
        }
    }
}
