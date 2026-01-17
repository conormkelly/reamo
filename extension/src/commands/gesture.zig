const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../gesture_state.zig");
const logging = @import("../logging.zig");
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
    } else if (std.mem.eql(u8, control_type_str, "hwOutputVolume")) {
        const hw_idx = cmd.getInt("hwIdx") orelse return null;
        return gesture_state.ControlId.hwOutputVolume(track_idx, hw_idx);
    } else if (std.mem.eql(u8, control_type_str, "hwOutputPan")) {
        const hw_idx = cmd.getInt("hwIdx") orelse return null;
        return gesture_state.ControlId.hwOutputPan(track_idx, hw_idx);
    }
    return null;
}

/// Handle gesture/start - called when a client begins dragging a fader
/// Params: { controlType: "volume"|"pan"|"send"|"sendPan"|"hwOutputVolume"|"hwOutputPan", trackIdx|trackGuid: number|string, sendIdx?/hwIdx?: number }
pub fn handleStart(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const gestures = response.gestures orelse {
        logging.warn("gesture/start called but GestureState not available", .{});
        response.err("INTERNAL_ERROR", "Gesture tracking not initialized");
        return;
    };

    const control = parseControlId(api, cmd) orelse {
        response.err("INVALID_PARAMS", "Required: controlType, trackIdx/trackGuid, and sendIdx/hwIdx for send/hw types");
        return;
    };

    const is_new = gestures.beginGesture(control, response.client_id);
    logging.debug("GESTURE START {s} track {d} (new={}, client={})", .{
        @tagName(control.control_type),
        control.track_idx,
        is_new,
        response.client_id,
    });

    // For hw output gestures, manage shared undo block (CSurf doesn't support category 1)
    // All hw gestures share one undo block since REAPER doesn't support nested blocks.
    if (is_new and gesture_state.GestureState.isHwOutputControl(control.control_type)) {
        const should_open = gestures.beginHwUndoBlock();
        if (should_open) {
            logging.debug("Opening shared HW undo block", .{});
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
        // For hw output gestures, manage shared undo block (CSurf doesn't support category 1)
        if (gesture_state.GestureState.isHwOutputControl(control.control_type)) {
            const should_close = gestures.endHwUndoBlock();
            if (should_close) {
                logging.debug("Closing shared HW undo block", .{});
                // Generic description since multiple hw controls may have been adjusted
                api.undoEndBlock("REAmo: Adjust audio hardware outputs");
            }
        } else {
            // For CSurf-based controls (track/send volume/pan), flush pending undo
            logging.debug("Calling CSurf_FlushUndo(true)", .{});
            api.csurfFlushUndo(true);
        }
    }

    response.success(null);
}
