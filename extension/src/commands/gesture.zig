const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../server/gesture_state.zig");
const logging = @import("../core/logging.zig");
const tracks = @import("tracks.zig");

/// Parse control type from command params.
/// Accepts either trackIdx or trackGuid (using resolveTrack pattern).
fn parseControlId(api: anytype, cmd: protocol.CommandMessage) ?gesture_state.ControlId {
    const control_type_str = cmd.getString("controlType") orelse return null;

    // Resolve track from either trackIdx or trackGuid
    const resolution = tracks.resolveTrack(api, cmd) orelse return null;
    const track_idx = resolution.idx;

    if (std.mem.eql(u8, control_type_str, "volume")) {
        return gesture_state.ControlId.volume(track_idx);
    } else if (std.mem.eql(u8, control_type_str, "pan")) {
        return gesture_state.ControlId.pan(track_idx);
    } else if (std.mem.eql(u8, control_type_str, "send")) {
        const send_idx = cmd.getInt("sendIdx") orelse return null;
        return gesture_state.ControlId.sendVolume(track_idx, send_idx);
    } else if (std.mem.eql(u8, control_type_str, "sendPan")) {
        const send_idx = cmd.getInt("sendIdx") orelse return null;
        return gesture_state.ControlId.sendPan(track_idx, send_idx);
    } else if (std.mem.eql(u8, control_type_str, "receive")) {
        const recv_idx = cmd.getInt("recvIdx") orelse return null;
        return gesture_state.ControlId.receiveVolume(track_idx, recv_idx);
    } else if (std.mem.eql(u8, control_type_str, "receivePan")) {
        const recv_idx = cmd.getInt("recvIdx") orelse return null;
        return gesture_state.ControlId.receivePan(track_idx, recv_idx);
    } else if (std.mem.eql(u8, control_type_str, "hwOutputVolume")) {
        const hw_idx = cmd.getInt("hwIdx") orelse return null;
        return gesture_state.ControlId.hwOutputVolume(track_idx, hw_idx);
    } else if (std.mem.eql(u8, control_type_str, "hwOutputPan")) {
        const hw_idx = cmd.getInt("hwIdx") orelse return null;
        return gesture_state.ControlId.hwOutputPan(track_idx, hw_idx);
    } else if (std.mem.eql(u8, control_type_str, "fxParam")) {
        const fx_guid = cmd.getString("fxGuid") orelse return null;
        const param_idx = cmd.getInt("paramIdx") orelse return null;
        return gesture_state.ControlId.fxParam(track_idx, fx_guid, param_idx);
    }
    return null;
}

/// Handle gesture/start - called when a client begins dragging a fader
/// Params: { controlType: "volume"|"pan"|"send"|"sendPan"|"receive"|"receivePan"|"hwOutputVolume"|"hwOutputPan", trackIdx|trackGuid: number|string, sendIdx?/recvIdx?/hwIdx?: number }
pub fn handleStart(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const gestures = response.gestures orelse {
        logging.warn("gesture/start called but GestureState not available", .{});
        response.err("INTERNAL_ERROR", "Gesture tracking not initialized");
        return;
    };

    const control = parseControlId(api, cmd) orelse {
        response.err("INVALID_PARAMS", "Required: controlType, trackIdx/trackGuid, and sendIdx/recvIdx/hwIdx for send/receive/hw types");
        return;
    };

    const is_new = gestures.beginGesture(control, response.client_id);
    logging.debug("GESTURE START {s} track {d} (new={}, client={})", .{
        @tagName(control.control_type),
        control.track_idx,
        is_new,
        response.client_id,
    });

    // For manual-undo controls (hw outputs, FX params), manage shared undo block.
    // CSurf doesn't support these categories. REAPER doesn't support nested blocks,
    // so all manual-undo gestures share one block.
    if (is_new and gesture_state.GestureState.needsManualUndo(control.control_type)) {
        const should_open = gestures.beginManualUndoBlock(control.control_type);
        if (should_open) {
            logging.debug("Opening shared manual undo block for {s}", .{@tagName(control.control_type)});
            api.undoBeginBlock();
        }
    }

    response.success(null);
}

/// Handle gesture/end - called when a client finishes dragging a fader
/// Params: { controlType: "volume"|"pan"|"send"|"sendPan"|"hwOutputVolume"|"hwOutputPan", trackIdx|trackGuid: number|string, sendIdx?/hwIdx?: number }
/// If this is the last client gesturing on the control, flushes the undo
pub fn handleEnd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const gestures = response.gestures orelse {
        logging.warn("gesture/end called but GestureState not available", .{});
        response.err("INTERNAL_ERROR", "Gesture tracking not initialized");
        return;
    };

    const control = parseControlId(api, cmd) orelse {
        response.err("INVALID_PARAMS", "Required: controlType, trackIdx/trackGuid, and sendIdx/hwIdx for send/hw types");
        return;
    };

    const should_flush = gestures.endGesture(control, response.client_id);
    logging.debug("GESTURE END {s} track {d} (flush={}, client={})", .{
        @tagName(control.control_type),
        control.track_idx,
        should_flush,
        response.client_id,
    });

    if (should_flush) {
        // For manual-undo controls (hw outputs, FX params), manage shared undo block.
        if (gesture_state.GestureState.needsManualUndo(control.control_type)) {
            const should_close = gestures.endManualUndoBlock(control.control_type);
            if (should_close) {
                const undo_msg = gestures.getManualUndoMessage();
                logging.debug("Closing shared manual undo block: {s}", .{undo_msg});
                api.undoEndBlock(undo_msg);
            }
        } else {
            // For CSurf-based controls (track/send volume/pan), flush pending undo
            logging.debug("Calling CSurf_FlushUndo(true)", .{});
            api.csurfFlushUndo(true);
        }
    }

    response.success(null);
}
